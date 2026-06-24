// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ILAWPComplianceEngine } from "../../src/interfaces/ILAWPComplianceEngine.sol";

/*//////////////////////////////////////////////////////////////
                        MALICIOUS MOCKS
//////////////////////////////////////////////////////////////*/

/// @title MaliciousRelayer
/// @notice Simulates an attacker attempting replay attacks after a valid proposal execution.
contract MaliciousRelayer {
    ILAWPComplianceEngine public engine;

    constructor(address _engine) {
        engine = ILAWPComplianceEngine(_engine);
    }

    /// @notice Attempts to trigger a double deposit by calling processPoolDeposit twice
    ///         with the same poolId in a single transaction.
    function doubleDeposit(
        uint256 _poolId,
        uint256 _amount,
        address[] calldata _contributors,
        uint256[] calldata _wadShares
    ) external {
        engine.processPoolDeposit(_poolId, _amount, _contributors, _wadShares);
        // Second call must revert - PoolAlreadyExists
        engine.processPoolDeposit(_poolId, _amount, _contributors, _wadShares);
    }
}

/// @title ReentrantClaimer
/// @notice Attempts reentrancy on claimYield / claimOperationalFunds.
/// @dev The compliance engine's nonReentrant guard should prevent this.
contract ReentrantClaimer {
    ILAWPComplianceEngine public engine;
    uint256 public tokenId;
    bool public attackFired;

    constructor(address _engine) {
        engine = ILAWPComplianceEngine(_engine);
    }

    function setTokenId(uint256 _tokenId) external {
        tokenId = _tokenId;
    }

    /// @dev Called by the ERC20 receive hook (if any) or crafted to re-enter.
    ///      In practice this tests that the guard reverts the recursive call.
    function attackYield() external {
        attackFired = false;
        engine.claimYield(tokenId);
    }

    /// @dev Fallback attempts re-entry into claimYield
    receive() external payable {
        if (!attackFired) {
            attackFired = true;
            engine.claimYield(tokenId); // Must revert with ReentrancyGuardReentrantCall
        }
    }
}

/// @title ReentrantOperationalClaimer
/// @notice Attempts reentrancy on claimOperationalFunds.
contract ReentrantOperationalClaimer {
    ILAWPComplianceEngine public engine;
    bool public attackFired;

    constructor(address _engine) {
        engine = ILAWPComplianceEngine(_engine);
    }

    function attack() external {
        attackFired = false;
        engine.claimOperationalFunds(msg.sender);
    }

    receive() external payable {
        if (!attackFired) {
            attackFired = true;
            engine.claimOperationalFunds(msg.sender); // Must revert
        }
    }
}

/// @title MaliciousERC20
/// @notice A token that reverts on transferFrom to test failed-transfer reversal.
contract MaliciousERC20 is IERC20 {
    bool public transferFromShouldFail;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string public name = "MaliciousToken";
    string public symbol = "MAL";
    uint8 public decimals = 18;

    function setTransferFromShouldFail(bool _fail) external {
        transferFromShouldFail = _fail;
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        override
        returns (bool)
    {
        if (transferFromShouldFail) {
            revert("MaliciousERC20: transferFrom deliberately failing");
        }
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @title MockEngineWithCalculateYield
/// @notice A mock compliance engine for ImpactToken tests that returns a controllable
///         pending yield value and tracks claimYield calls.
contract MockEngineWithCalculateYield {
    bool public claimYieldCalled;
    uint256 public pendingYieldToReturn;
    address public lastClaimedFor;

    function setPendingYield(uint256 _amount) external {
        pendingYieldToReturn = _amount;
    }

    function calculateProportionalYield(uint256) external view returns (uint256) {
        return pendingYieldToReturn;
    }

    function claimYield(uint256) external {
        claimYieldCalled = true;
        lastClaimedFor = msg.sender;
    }
}
