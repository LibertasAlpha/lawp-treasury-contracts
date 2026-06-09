// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ============================================================
// MockAdminOperations
// ============================================================
// Replaces the inlined mappings with a proper external contract
// so the token contract delegates to it - exactly as production does.
//
// Key addition: `removeCanMintShouldFail` flag lets tests exercise
// the revert path inside mint() that the original mock could never reach.
// ============================================================

contract MockAdminOperations {
    // ---- State ----
    mapping(address => bool) public blacklisted;
    mapping(address => bool) public internalWhitelisted;
    mapping(address => bool) public externalWhitelisted;
    mapping(address => bool) public canMintMap;
    mapping(address => uint256) public mintAmountMap;

    /// @dev When true, removeCanMint() reverts - mirrors a broken/hostile admin contract.
    bool public removeCanMintShouldFail;

    // ---- IAdmin interface (matches production IOperations / IAdmin) ----

    function isBlackListed(address account) external view returns (bool) {
        return blacklisted[account];
    }

    function isInternalUserWhitelisted(address account) external view returns (bool) {
        return internalWhitelisted[account];
    }

    function isExternalSenderWhitelisted(address account) external view returns (bool) {
        return externalWhitelisted[account];
    }

    function canMint(address account) external view returns (bool) {
        return canMintMap[account];
    }

    function mintAmount(address account) external view returns (uint256) {
        return mintAmountMap[account];
    }

    /**
     * @dev Reverts when removeCanMintShouldFail == true, allowing tests to verify
     * that MockCngn3.mint() rolls back the entire transaction on admin failure -
     * behaviour that the old inlined mock could never exercise.
     */
    function removeCanMint(address account) external returns (bool) {
        require(!removeCanMintShouldFail, "MockAdmin: removeCanMint deliberately failing");
        canMintMap[account] = false;
        mintAmountMap[account] = 0;
        return true;
    }

    // ---- Test-configuration helpers ----

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    function setInternalWhitelisted(address account, bool status) external {
        internalWhitelisted[account] = status;
    }

    function setExternalWhitelisted(address account, bool status) external {
        externalWhitelisted[account] = status;
    }

    function setCanMint(address account, uint256 amount) external {
        canMintMap[account] = true;
        mintAmountMap[account] = amount;
    }

    /// @dev Toggle to simulate a failing admin contract during mint revocation.
    function setRemoveCanMintShouldFail(bool shouldFail) external {
        removeCanMintShouldFail = shouldFail;
    }

    // ---- Bulk helpers ----

    function setupMinters(address[] calldata minters, uint256[] calldata amounts) external {
        require(minters.length == amounts.length, "MockAdmin: length mismatch");
        for (uint256 i = 0; i < minters.length; i++) {
            canMintMap[minters[i]] = true;
            mintAmountMap[minters[i]] = amounts[i];
        }
    }

    function setupRedemptionScenario(address externalUser, address internalUser) external {
        externalWhitelisted[externalUser] = true;
        internalWhitelisted[internalUser] = true;
    }
}

// ============================================================
// IAdmin - minimal interface MockCngn3 calls into
// ============================================================

interface IAdmin {
    function isBlackListed(address account) external view returns (bool);
    function isInternalUserWhitelisted(address account) external view returns (bool);
    function isExternalSenderWhitelisted(address account) external view returns (bool);
    function canMint(address account) external view returns (bool);
    function mintAmount(address account) external view returns (uint256);
    function removeCanMint(address account) external returns (bool);
}

// ============================================================
// MockCngn3
// ============================================================
// Changes vs the original mock
// ---------------------------------------------------------------
// [FIX-1] Delegates all access-control reads to MockAdminOperations
//         via IAdmin - exactly matching production.  The old inlined
//         mappings are gone.
//
// [FIX-2] mint() now calls adminOperationsContract.removeCanMint()
//         and requires it to succeed, matching the production revert
//         path that the old mock silently skipped.
//
// [FIX-3] _beforeTokenTransfer hook re-introduced with whenNotPaused
//         so pause enforcement happens at the same ERC-20 layer as
//         production (not only on the public-function guards).
//
// [FIX-4] mintTest() is now onlyOwner-gated to prevent accidental
//         bypass of the real mint flow in test setups.
// ============================================================

contract MockCngn3 is ERC20, Ownable, ReentrancyGuard {
    // ---- Events ----
    event DestroyedBlackFunds(address indexed user, uint256 amount);
    event UpdateForwarderContract(address indexed oldAddress, address indexed newAddress);

    // ---- Constants ----
    uint8 private constant _DECIMALS = 6;

    // ---- State ----
    address public trustedForwarderContract;
    address public adminOperationsContract; // now actually called - not dead storage
    bool private _paused;

    // ---- Modifiers ----
    modifier whenNotPaused() {
        require(!_paused, "Pausable: paused");
        _;
    }

    modifier onlyTrustedForwarderCaller() {
        require(isTrustedForwarder(msg.sender), "Not trusted forwarder");
        _;
    }

    // ---- Constructor ----
    constructor(address _adminOperationsContract) ERC20("cNGN", "cNGN") Ownable(msg.sender) {
        require(_adminOperationsContract != address(0), "Zero admin address");
        adminOperationsContract = _adminOperationsContract;
    }

    // ---- Decimals ----
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    // ---- Forwarder ----
    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == trustedForwarderContract;
    }

    function updateForwarderContract(address _newForwarderContract)
        external
        onlyOwner
        returns (bool)
    {
        require(_newForwarderContract != address(0), "Zero address");
        emit UpdateForwarderContract(trustedForwarderContract, _newForwarderContract);
        trustedForwarderContract = _newForwarderContract;
        return true;
    }

    // ---- Meta-TX support ----
    function _msgSender() internal view override returns (address sender) {
        if (msg.data.length >= 20 && isTrustedForwarder(msg.sender)) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    // ---- Transfer ----

    /**
     * @dev Mirrors production transfer():
     * - Delegates blacklist / whitelist checks to adminOperationsContract (IAdmin).
     * - Redemption path (external → internal) transfers then burns.
     */
    function transfer(address to, uint256 amount)
        public
        override
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        address owner = _msgSender();

        require(!IAdmin(adminOperationsContract).isBlackListed(owner), "Sender is blacklisted");
        require(!IAdmin(adminOperationsContract).isBlackListed(to), "Recipient is blacklisted");

        if (
            IAdmin(adminOperationsContract).isInternalUserWhitelisted(to)
                && IAdmin(adminOperationsContract).isExternalSenderWhitelisted(owner)
        ) {
            _transfer(owner, to, amount);
            _burn(to, amount);
        } else {
            _transfer(owner, to, amount);
        }

        return true;
    }

    /**
     * @dev Mirrors production transferFrom() - same delegation + redemption path.
     */
    function transferFrom(address from, address to, uint256 amount)
        public
        override
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        address spender = _msgSender();

        require(!IAdmin(adminOperationsContract).isBlackListed(spender), "Spender is blacklisted");
        require(!IAdmin(adminOperationsContract).isBlackListed(from), "Sender is blacklisted");
        require(!IAdmin(adminOperationsContract).isBlackListed(to), "Recipient is blacklisted");

        _spendAllowance(from, spender, amount);

        if (
            IAdmin(adminOperationsContract).isInternalUserWhitelisted(to)
                && IAdmin(adminOperationsContract).isExternalSenderWhitelisted(from)
        ) {
            _transfer(from, to, amount);
            _burn(to, amount);
        } else {
            _transfer(from, to, amount);
        }

        return true;
    }

    // ---- Mint ----

    /**
     * @dev [FIX-2] Delegates to adminOperationsContract for all checks AND for
     * removeCanMint(), matching the production revert path when the admin call fails.
     *
     * Old mock silently set _canMint[sender] = false in-place, so a failing
     * removeCanMint() could never be tested.
     */
    function mint(uint256 amount, address mintTo)
        external
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        address sender = _msgSender();

        require(!IAdmin(adminOperationsContract).isBlackListed(sender), "Signer is blacklisted");
        require(!IAdmin(adminOperationsContract).isBlackListed(mintTo), "Receiver is blacklisted");
        require(IAdmin(adminOperationsContract).canMint(sender), "Minter not authorized to sign");
        require(
            IAdmin(adminOperationsContract).mintAmount(sender) == amount,
            "Attempting to mint more than allowed"
        );

        _mint(mintTo, amount);

        // [FIX-2] This can now revert if MockAdminOperations.removeCanMintShouldFail == true.
        require(
            IAdmin(adminOperationsContract).removeCanMint(sender),
            "Failed to revoke minting authorization"
        );

        return true;
    }

    /**
     * @dev [FIX-4] Restricted to owner - prevents accidental bypass of the real
     * mint flow in tests.  Use only for seeding balances in test setup, never
     * as a substitute for testing mint() itself.
     */
    function mintTest(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    // ---- Burn ----

    function burnByUser(uint256 amount) external whenNotPaused nonReentrant returns (bool) {
        require(!IAdmin(adminOperationsContract).isBlackListed(_msgSender()), "User is blacklisted");
        _burn(_msgSender(), amount);
        return true;
    }

    function destroyBlackFunds(address blacklistedUser)
        external
        onlyOwner
        nonReentrant
        returns (bool)
    {
        require(IAdmin(adminOperationsContract).isBlackListed(blacklistedUser), "Not blacklisted");
        uint256 dirtyFunds = balanceOf(blacklistedUser);
        _burn(blacklistedUser, dirtyFunds);
        emit DestroyedBlackFunds(blacklistedUser, dirtyFunds);
        return true;
    }

    // ---- Pause ----

    function pause() external onlyOwner returns (bool) {
        _paused = true;
        return true;
    }

    function unpause() external onlyOwner returns (bool) {
        _paused = false;
        return true;
    }

    function paused() public view returns (bool) {
        return _paused;
    }

    // ---- [FIX-3] _beforeTokenTransfer hook ----
    /**
     * @dev Re-introduced so the pause guard fires at the internal ERC-20 layer,
     * exactly as in production where _beforeTokenTransfer is whenNotPaused.
     * This catches any hypothetical internal call path that bypasses the public
     * function modifier - keeping pause enforcement semantically identical.
     */
    function _update(address from, address to, uint256 amount) internal override whenNotPaused {
        super._update(from, to, amount);
    }

    // ---- Admin contract update (for test flexibility) ----

    function setAdminOperationsContract(address _admin) external onlyOwner {
        require(_admin != address(0), "Zero address");
        adminOperationsContract = _admin;
    }

    function setTrustedForwarder(address _forwarder) external onlyOwner {
        trustedForwarderContract = _forwarder;
    }

    // ---- Bulk setup helper (delegates to MockAdminOperations) ----

    /**
     * @dev Convenience: mint tokens to externalUser and configure whitelists
     * via the admin contract - keeps test setup going through the same
     * contract boundaries as production.
     */
    function setupRedemptionScenario(
        address externalUser,
        address internalUser,
        uint256 mintAmount_
    ) external onlyOwner {
        _mint(externalUser, mintAmount_);
        MockAdminOperations(adminOperationsContract)
            .setupRedemptionScenario(externalUser, internalUser);
    }
}
