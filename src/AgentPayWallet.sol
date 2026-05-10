// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/IAgentPayWallet.sol";
import "./lib/AgentPayErrors.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AgentPayWallet
 * @notice Multi-owner, multi-token, operator-centric wallet that holds funds for every
 *  channel in the AgentPay network. Designed as a permanent, audited custodian — it
 *  has no business logic of its own and does not trust any external contract,
 *  including AgentPayLedger. A single global instance is shared across ledger versions,
 *  and operatorship can be transferred cooperatively to enable channel migration.
 * @dev See {IAgentPayWallet} for canonical NatSpec on each function.
 */
contract AgentPayWallet is IAgentPayWallet, Pausable, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Hard cap on `owners.length` per wallet.
    uint256 public constant MAX_OWNERS = 10;

    struct Wallet {
        // corresponding to peers in AgentPayLedger
        address[] owners;
        // corresponding to AgentPayLedger
        address operator;
        // address(0) for native
        mapping(address => uint256) balances;
        // operator candidate currently being voted on; address(0) when no vote in flight
        address pendingOperator;
        // owner => has-voted for the current pendingOperator
        mapping(address => bool) votes;
    }

    uint256 public walletCount;
    mapping(bytes32 => Wallet) private wallets;

    constructor() Ownable(msg.sender) {}

    // -------------------------------------------------------------------------
    // Modifiers and internal checks
    // -------------------------------------------------------------------------

    /// @dev Throws if called by any account other than the wallet's operator.
    modifier onlyOperator(bytes32 _walletId) {
        _checkOperator(_walletId);
        _;
    }

    /// @dev Throws if `_addr` is not an owner of the wallet.
    modifier onlyWalletOwner(bytes32 _walletId, address _addr) {
        _checkWalletOwner(_walletId, _addr);
        _;
    }

    function _checkOperator(bytes32 _walletId) internal view {
        require(msg.sender == wallets[_walletId].operator, AgentPayErrors.NotOperator());
    }

    function _checkWalletOwner(bytes32 _walletId, address _addr) internal view {
        require(_isWalletOwner(_walletId, _addr), AgentPayErrors.NotWalletOwner());
    }

    // -------------------------------------------------------------------------
    // External / state-changing API
    // -------------------------------------------------------------------------

    /// @inheritdoc IAgentPayWallet
    function create(address[] calldata _owners, address _operator, bytes32 _nonce)
        external
        whenNotPaused
        returns (bytes32)
    {
        require(_operator != address(0), AgentPayErrors.ZeroAddress());
        require(_owners.length <= MAX_OWNERS, AgentPayErrors.TooManyOwners());

        bytes32 walletId = keccak256(abi.encodePacked(block.chainid, address(this), msg.sender, _nonce));
        Wallet storage w = wallets[walletId];
        // wallet must be uninitialized
        require(w.operator == address(0), AgentPayErrors.WalletIdOccupied());
        w.owners = _owners;
        w.operator = _operator;
        walletCount++;

        emit WalletCreated(walletId, _owners, _operator);
        return walletId;
    }

    /// @inheritdoc IAgentPayWallet
    function depositNative(bytes32 _walletId) external payable whenNotPaused {
        uint256 amount = msg.value;
        wallets[_walletId].balances[address(0)] += amount;
        emit Deposited(_walletId, address(0), amount);
    }

    /// @inheritdoc IAgentPayWallet
    function depositERC20(bytes32 _walletId, address _tokenAddress, uint256 _amount) external whenNotPaused {
        wallets[_walletId].balances[_tokenAddress] += _amount;
        emit Deposited(_walletId, _tokenAddress, _amount);

        IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @inheritdoc IAgentPayWallet
     * @dev CEI: balance debit precedes the external transfer. Combined with
     *  Solidity 0.8's checked arithmetic, this bounds any reentrant
     *  withdraw chain at the wallet's actual balance — equivalent to N
     *  sequential withdraw calls.
     */
    function withdraw(bytes32 _walletId, address _tokenAddress, address _receiver, uint256 _amount)
        external
        whenNotPaused
        onlyOperator(_walletId)
        onlyWalletOwner(_walletId, _receiver)
    {
        // Solidity 0.8 checked subtraction reverts on underflow if the wallet
        // doesn't hold enough of `_tokenAddress` — implicit balance gate.
        wallets[_walletId].balances[_tokenAddress] -= _amount;
        emit Withdrawn(_walletId, _tokenAddress, _receiver, _amount);

        _withdrawToken(_tokenAddress, _receiver, _amount);
    }

    /// @inheritdoc IAgentPayWallet
    function transferBetweenWallets(
        bytes32 _fromWalletId,
        bytes32 _toWalletId,
        address _tokenAddress,
        address _receiver,
        uint256 _amount
    )
        external
        whenNotPaused
        onlyOperator(_fromWalletId)
        onlyWalletOwner(_fromWalletId, _receiver)
        onlyWalletOwner(_toWalletId, _receiver)
    {
        wallets[_fromWalletId].balances[_tokenAddress] -= _amount;
        wallets[_toWalletId].balances[_tokenAddress] += _amount;
        emit TransferredBetweenWallets(_fromWalletId, _toWalletId, _tokenAddress, _receiver, _amount);
    }

    /// @inheritdoc IAgentPayWallet
    function transferOperatorship(bytes32 _walletId, address _newOperator)
        external
        whenNotPaused
        onlyOperator(_walletId)
    {
        _changeOperator(_walletId, _newOperator);
    }

    /// @inheritdoc IAgentPayWallet
    function voteForOperator(bytes32 _walletId, address _candidate) external onlyWalletOwner(_walletId, msg.sender) {
        require(_candidate != address(0), AgentPayErrors.ZeroAddress());

        Wallet storage w = wallets[_walletId];
        // Voting for a different candidate replaces the in-flight proposal
        // and resets every owner's tally — consensus is per-candidate.
        if (_candidate != w.pendingOperator) {
            _clearVotes(w);
            w.pendingOperator = _candidate;
        }

        w.votes[msg.sender] = true;
        emit OperatorVoted(_walletId, _candidate, msg.sender);

        // _changeOperator clears the pendingOperator + vote tally on success.
        if (_checkAllVotes(w)) {
            _changeOperator(_walletId, _candidate);
        }
    }

    /// @inheritdoc IAgentPayWallet
    function drainToken(address _tokenAddress, address _receiver, uint256 _amount) external whenPaused onlyOwner {
        emit TokenDrained(_tokenAddress, _receiver, _amount);

        _withdrawToken(_tokenAddress, _receiver, _amount);
    }

    /// @notice Pause the wallet. Owner-only. Blocks deposits / withdrawals / operator changes.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume normal operation after a pause. Owner-only.
    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // External views
    // -------------------------------------------------------------------------

    /// @inheritdoc IAgentPayWallet
    function walletOwners(bytes32 _walletId) external view returns (address[] memory) {
        return wallets[_walletId].owners;
    }

    /// @inheritdoc IAgentPayWallet
    function walletOperator(bytes32 _walletId) external view returns (address) {
        return wallets[_walletId].operator;
    }

    /// @inheritdoc IAgentPayWallet
    function balanceOf(bytes32 _walletId, address _tokenAddress) external view returns (uint256) {
        return wallets[_walletId].balances[_tokenAddress];
    }

    /// @inheritdoc IAgentPayWallet
    function pendingOperator(bytes32 _walletId) external view returns (address) {
        return wallets[_walletId].pendingOperator;
    }

    /// @inheritdoc IAgentPayWallet
    function hasVoted(bytes32 _walletId, address _owner) external view returns (bool) {
        return wallets[_walletId].votes[_owner];
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @notice Send `_amount` of `_tokenAddress` to `_receiver`. Native uses
    ///  raw `.call{value:}` (see {withdraw} NatSpec for reentrancy notes);
    ///  ERC-20 routes through OpenZeppelin `SafeERC20`.
    function _withdrawToken(address _tokenAddress, address _receiver, uint256 _amount) internal {
        if (_tokenAddress == address(0)) {
            (bool success,) = payable(_receiver).call{value: _amount}("");
            require(success, AgentPayErrors.NativeTransferFailed());
        } else {
            IERC20(_tokenAddress).safeTransfer(_receiver, _amount);
        }
    }

    /// @notice Clear all owners' votes on the current pendingOperator.
    function _clearVotes(Wallet storage _w) internal {
        uint256 n = _w.owners.length;
        for (uint256 i = 0; i < n;) {
            _w.votes[_w.owners[i]] = false;
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Internal operator change. Also clears any in-flight pending
    ///  candidate — the just-completed change supersedes any pending vote, and
    ///  leaving stale state confuses subsequent {voteForOperator} calls.
    function _changeOperator(bytes32 _walletId, address _newOperator) internal {
        require(_newOperator != address(0), AgentPayErrors.ZeroAddress());

        Wallet storage w = wallets[_walletId];
        address oldOperator = w.operator;
        w.operator = _newOperator;

        if (w.pendingOperator != address(0)) {
            _clearVotes(w);
            delete w.pendingOperator;
        }

        emit OperatorChanged(_walletId, oldOperator, _newOperator);
    }

    /// @notice True iff every owner has voted for the current pendingOperator.
    function _checkAllVotes(Wallet storage _w) internal view returns (bool) {
        uint256 n = _w.owners.length;
        for (uint256 i = 0; i < n;) {
            if (_w.votes[_w.owners[i]] == false) {
                return false;
            }
            unchecked {
                ++i;
            }
        }
        return true;
    }

    /// @notice True iff `_addr` appears in the wallet's `owners` array.
    function _isWalletOwner(bytes32 _walletId, address _addr) internal view returns (bool) {
        Wallet storage w = wallets[_walletId];
        uint256 n = w.owners.length;
        for (uint256 i = 0; i < n;) {
            if (_addr == w.owners[i]) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }
}
