// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {AccessRegistry} from "../../src/AccessRegistry/AccessRegistry.sol";
import {UUPSUpgradeable} from "../../src/utils/UUPSUpgradeable.sol";
import {Initializable} from "../../src/utils/Initializable.sol";

/**
 * @title MultisigWallet
 * @notice Implements a multisig wallet with three types of actors:
 * 1. Super Admin: Can execute any function directly
 * 2. Fallback Admin: Can initiate mint/burn (requires signer approval)
 * 3. Signers: Can initiate and must approve all other functions
 */
contract MultiSigWallet is Initializable, AccessRegistry, UUPSUpgradeable {
    // ========== CONSTANTS ==========
    uint256 private constant SIGNER_WINDOW = 24 hours;
    uint256 private constant FALLBACK_ADMIN_WINDOW = 72 hours;
    uint256 private constant APPROVAL_THRESHOLD = 60; // 60% of signers must approve

    ///@dev bytes4(keccak256("mint(address,uint256)"))
    bytes4 public constant MINT_SELECTOR = 0x40c10f19;

    ///@dev bytes4(keccak256("burn(address,uint256)"))
    bytes4 public constant BURN_SELECTOR = 0x9dc29fac;

    ///@dev bytes4(keccak256("updateOperationalState(uint8)"))
    bytes4 public constant PAUSE_STATE_SELECTOR = 0x50f20190;

    ///@dev bytes4(keccak256("blackListAccount(address)"))
    bytes4 public constant BLACKLIST_ACCOUNT_SELECTOR = 0xe0644962;

    ///@dev bytes4(keccak256("removeBlackListedAccount(address)"))
    bytes4 public constant REMOVE_BLACKLIST_ACCOUNT_SELECTOR = 0xc460f1be;

    ///@dev bytes4(keccak256("recoverToken(address,address)"))
    bytes4 public constant RECOVER_TOKENS_SELECTOR = 0xfeaea586;

    ///@dev keccak256("HASH.token.hashstack.slot")
    bytes32 public constant TOKEN_CONTRACT_SLOT = 0x2e621e7466541a75ed3060ecb302663cf45f24d90bdac97ddad9918834bc5d75;

    // ========== ENUMS ==========
    enum TransactionState {
        Pending, // Just created, awaiting first signature
        Active, // Has at least one signature, within time window
        Queued, // Has enough signatures, ready for execution
        Expired, // Time window passed without enough signatures
        Executed // Successfully executed

    }

    // ========== STRUCTS ==========
    struct Transaction {
        address proposer;
        bytes4 selector; // The function call data
        bytes params;
        uint256 proposedAt; // When the transaction was proposed
        uint256 firstSignAt; // When the first signer approved
        uint256 approvals; // Number of approvals received
        TransactionState state; //state of the transaction(pending,)
        bool isFallbackAdmin; // Whether this was proposed by fallback admin
    }

    // ========== STATE ==========
    mapping(uint256 => Transaction) private transactions;
    mapping(uint256 => mapping(address => bool)) hasApproved;
    mapping(uint256 => bool) transactionIdExists;
    // Function permissions
    mapping(bytes4 => bool) fallbackAdminFunctions;
    mapping(bytes4 => bool) signerFunctions;

    // ========== EVENTS ==========
    event TransactionProposed(uint256 indexed txId, address proposer, uint256 proposedAt);
    event TransactionApproved(uint256 indexed txId, address signer);
    event TransactionRevoked(uint256 indexed txId, address revoker);
    event TransactionExecuted(uint256 indexed txId);
    event TransactionExpired(uint256 indexed txId);
    event TransactionStateChanged(uint256 indexed txId, TransactionState newState);
    event InsufficientApprovals(uint256 indexed txId, uint256 approvals);
    event TransactionProposedBySuperAdmin(uint256 proposedAt);

    // ========== ERRORS ==========
    error UnauthorizedCall();
    error InvalidToken();
    error InvalidState();
    error AlreadyApproved();
    error TransactionNotSigned();
    error WindowExpired();
    error TransactionAlreadyExist();
    error TransactionIdNotExist();
    error FunctionAlreadyExists();
    error FunctionDoesNotExist();

    // ========== INITIALIZATION ==========
    constructor() {
        _disableInitializers();
    }

    function initialize(address _superAdmin, address _fallbackAdmin, address _tokenContract)
        external
        initializer
        notZeroAddress(_superAdmin)
        notZeroAddress(_fallbackAdmin)
        notZeroAddress(_tokenContract)
    {
        _initializeAccessRegistry(_superAdmin, _fallbackAdmin);
        // Set up function permissions
        // Fallback admin can only mint and burn
        fallbackAdminFunctions[MINT_SELECTOR] = true;
        fallbackAdminFunctions[BURN_SELECTOR] = true;

        // Signers can pause/unpause and manage blacklist
        signerFunctions[PAUSE_STATE_SELECTOR] = true;
        signerFunctions[BLACKLIST_ACCOUNT_SELECTOR] = true;
        signerFunctions[REMOVE_BLACKLIST_ACCOUNT_SELECTOR] = true;
        signerFunctions[RECOVER_TOKENS_SELECTOR] = true;

        assembly {
            sstore(TOKEN_CONTRACT_SLOT, _tokenContract)
        }
    }

    // ========== CORE MULTISIG LOGIC ==========

    /**
     * @notice Updates the transaction state based on current conditions
     * @param txId The transaction ID to update
     * @return The current state of the transaction
     */
    function updateTransactionState(uint256 txId) public txExist(txId) returns (TransactionState) {
        Transaction storage transaction = transactions[txId];

        // Don't update final states
        if (transaction.state == TransactionState.Executed || transaction.state == TransactionState.Expired) {
            return transaction.state;
        }

        uint256 currentTime = block.timestamp;
        bool isExpired;

        // Check expiration based on transaction type
        if (transaction.isFallbackAdmin) {
            uint256 fallbackAdminDeadline = transaction.proposedAt + FALLBACK_ADMIN_WINDOW;
            uint256 deadline = transaction.firstSignAt != 0
                ? min(fallbackAdminDeadline, transaction.firstSignAt + SIGNER_WINDOW)
                : fallbackAdminDeadline;
            isExpired = currentTime > deadline;
        } else {
            isExpired = currentTime > transaction.proposedAt + SIGNER_WINDOW;
        }

        // Update state based on conditions
        TransactionState newState = transaction.state;
        uint256 totalSigner = totalSigners();

        if (isExpired) {
            if ((transaction.approvals * 100) / totalSigner >= APPROVAL_THRESHOLD) {
                newState = TransactionState.Queued;
            } else {
                emit InsufficientApprovals(txId, transaction.approvals);
                newState = TransactionState.Expired;
            }
        } else if (transaction.firstSignAt != 0) {
            newState = TransactionState.Active;
        }

        if (newState != transaction.state) {
            transaction.state = newState;
            emit TransactionStateChanged(txId, transaction.state);
        }

        return newState;
    }

    function createBatchTransaction(bytes4[] calldata _selector, bytes[] calldata _params)
        external
        returns (uint256[] memory txId)
    {
        if (_selector.length != _params.length) revert();
        uint256 size = _selector.length;

        if (_msgSender() == superAdmin()) {
            for (uint256 i = 0; i < size; i++) {
                emit TransactionProposedBySuperAdmin(block.timestamp);
                _call(_selector[i], _params[i]);
            }
        } else {
            for (uint256 i = 0; i < size; i++) {
                txId[i] = createTransaction(_selector[i], _params[i]);
            }
        }
    }

    /**
     * @notice Checks if a transaction ID is valid
     * @param txId The transaction ID to check
     * @return flag True if the transaction ID is valid, false otherwise
     */
    function isValidTransaction(uint256 txId) public view returns (bool flag) {
        assembly {
            mstore(0x00, txId)
            mstore(0x20, transactionIdExists.slot)
            let transactionKey := keccak256(0x00, 0x40)
            flag := sload(transactionKey)
        }
    }

    /**
     * @notice Proposes a new transaction
     * @param _selector The function call data to execute
     * @param _params Parameters needs to passed with functional call
     */
    function createTransaction(bytes4 _selector, bytes memory _params) internal returns (uint256 txId) {
        bool isSigner = isSigner(_msgSender());
        bool isFallbackAdmin = _msgSender() == fallbackAdmin();
        bool isValidFunction = isSigner ? signerFunctions[_selector] : fallbackAdminFunctions[_selector];

        if (!isValidFunction || (!isSigner && !isFallbackAdmin)) {
            revert UnauthorizedCall();
        }

        txId = uint256(keccak256(abi.encode(block.timestamp, _msgSender(), _selector, _params)));

        if (isValidTransaction(txId)) {
            revert TransactionAlreadyExist();
        }

        transactionIdExists[txId] = true;

        transactions[txId] = Transaction({
            proposer: _msgSender(),
            selector: _selector,
            params: _params,
            proposedAt: block.timestamp,
            firstSignAt: 0,
            approvals: 0,
            state: TransactionState.Pending,
            isFallbackAdmin: isFallbackAdmin
        });

        emit TransactionProposed(txId, _msgSender(), block.timestamp);

        return txId;
    }

    /**
     * @notice Approves a transaction
     * @param txId The transaction ID to approve
     */
    function approveTransaction(uint256 txId) public virtual txExist(txId) {
        if (!isSigner(_msgSender())) revert UnauthorizedCall();
        if (hasApproved[txId][_msgSender()]) revert AlreadyApproved();

        Transaction storage transaction = transactions[txId];
        TransactionState currentState = updateTransactionState(txId);

        if (currentState != TransactionState.Pending && currentState != TransactionState.Active) {
            revert InvalidState();
        }

        // Update first signature time if this is the first approval
        if (transaction.approvals == 0) {
            transaction.firstSignAt = block.timestamp;
        }
        unchecked {
            transaction.approvals += 1;
        }
        hasApproved[txId][_msgSender()] = true;

        emit TransactionApproved(txId, _msgSender());
        updateTransactionState(txId);
    }

    function approveBatchTransaction(uint256[] calldata txId) external virtual {
        for (uint256 i = 0; i < txId.length; i++) {
            approveTransaction(txId[i]);
        }
    }

    function revokeBatchTransaction(uint256[] calldata txId) external virtual {
        for (uint256 i = 0; i < txId.length; i++) {
            revokeConfirmation(txId[i]);
        }
    }

    /**
     * @notice Revokes a previously approved transaction
     * @param txId The transaction ID to revoke
     */
    function revokeConfirmation(uint256 txId) public virtual txExist(txId) {
        if (!isSigner(_msgSender())) revert UnauthorizedCall();
        if (!hasApproved[txId][_msgSender()]) revert TransactionNotSigned();

        Transaction storage transaction = transactions[txId];
        TransactionState currentState = updateTransactionState(txId);

        if (currentState != TransactionState.Active) {
            revert InvalidState();
        }
        unchecked {
            transaction.approvals -= 1;
        }
        hasApproved[txId][_msgSender()] = false;

        emit TransactionRevoked(txId, _msgSender());

        updateTransactionState(txId);
    }

    function executeBatchTransaction(uint256[] calldata txId) external virtual {
        for (uint256 i = 0; i < txId.length; i++) {
            executeTransaction(txId[i]);
        }
    }

    /**
     * @notice Executes a transaction if it has enough approvals
     * @param txId The transaction ID to execute
     */
    function executeTransaction(uint256 txId) public virtual txExist(txId) {
        Transaction storage transaction = transactions[txId];
        TransactionState currentState = updateTransactionState(txId);

        if (currentState != TransactionState.Queued) {
            revert InvalidState();
        }
        transaction.state = TransactionState.Executed;

        _call(transaction.selector, transaction.params);

        emit TransactionExecuted(txId);
    }

    /**
     * @notice Calls a function on the token contract
     * @param functionSelector The function selector for the call
     * @param callData The call data for the function
     */
    function _call(bytes4 functionSelector, bytes memory callData) internal {
        // solhint-disable-next-line avoid-low-level-calls
        address token = tokenContract();
        (bool success,) = token.call(abi.encodePacked(functionSelector, callData));
        if (!success) {
            // If the call failed, we revert with the propagated error message.
            // solhint-disable-next-line no-inline-assembly
            assembly {
                let returnDataSize := returndatasize()
                returndatacopy(0, 0, returnDataSize)
                revert(0, returnDataSize)
            }
        }
    }

    // ========== VIEW FUNCTIONS ==========

    function getTransaction(uint256 txId)
        external
        view
        txExist(txId)
        returns (
            address proposer,
            bytes4 selector,
            bytes memory params,
            uint256 proposedAt,
            uint256 firstSignAt,
            uint256 approvals,
            TransactionState state,
            bool isFallbackAdmin
        )
    {
        Transaction storage trnx = transactions[txId];
        return (
            trnx.proposer,
            trnx.selector,
            trnx.params,
            trnx.proposedAt,
            trnx.firstSignAt,
            trnx.approvals,
            trnx.state,
            trnx.isFallbackAdmin
        );
    }

    /**
     * @notice Authorizes contract upgrade
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlySuperAdmin {}

    modifier txExist(uint256 txId) {
        if (!isValidTransaction(txId)) {
            revert TransactionIdNotExist();
        }
        _;
    }

    function tokenContract() public view returns (address token) {
        assembly {
            token := sload(TOKEN_CONTRACT_SLOT)
        }
    }

    /// @dev Returns the minimum of `x` and `y`.
    function min(uint256 x, uint256 y) private pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            z := xor(x, mul(xor(x, y), lt(y, x)))
        }
    }
}