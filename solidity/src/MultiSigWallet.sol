// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {AccessRegistry} from "./AccessRegistry/AccessRegistry.sol";
import {UUPSUpgradeable} from "./utils/UUPSUpgradeable.sol";
import {Initializable} from "./utils/Initializable.sol";

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

    // Pre-calculated function selectors

    ///@dev bytes4(keccak256("mint(address,uint256)"))
    bytes4 private constant MINT_SELECTOR = 0x40c10f19;

    ///@dev bytes4(keccak256("burn(address,uint256)"))
    bytes4 private constant BURN_SELECTOR = 0x9dc29fac;

    ///@dev bytes4(keccak256("pause()"))
    bytes4 private constant PAUSE_SELECTOR = 0x8456cb59;

    ///@dev bytes4(keccak256("unpause()"))
    bytes4 private constant UNPAUSE_SELECTOR = 0x3f4ba83a;

    ///@dev bytes4(keccak256("blacklistAccount(address)"))
    bytes4 private constant BLACKLIST_ACCOUNT_SELECTOR = 0xd37b34d7;

    ///@dev bytes4(keccak256("removeBlacklistedAccount(address)"))
    bytes4 private constant REMOVE_BLACKLIST_ACCOUNT_SELECTOR = 0xb24822c5;

    ///@dev bytes4(keccak256("recoverToken(address,address)"))
    bytes4 private constant RECOVER_TOKENS_SELECTOR = 0xfeaea586;

    ///@dev keccak256("HASH.token.hashstack.slot")
    bytes32 private constant TOKEN_CONTRACT_SLOT = 0x2e621e7466541a75ed3060ecb302663cf45f24d90bdac97ddad9918834bc5d75;

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
        TransactionState state;
        bool isFallbackAdmin; // Whether this was proposed by fallback admin
    }

    // ========== STATE ==========
    mapping(uint256 => Transaction) private transactions;
    mapping(uint256 => mapping(address => bool)) public hasApproved;
    mapping(uint256 => bool) private transactionIdExists;
    // Function permissions
    mapping(bytes4 => bool) public fallbackAdminFunctions;
    mapping(bytes4 => bool) public signerFunctions;

    // ========== EVENTS ==========
    event TransactionProposed(uint256 indexed txId, address proposer, uint256 proposedAt);
    event TransactionApproved(uint256 indexed txId, address signer);
    event TransactionRevoked(uint256 indexed txId, address revoker);
    event TransactionExecuted(uint256 indexed txId);
    event TransactionExpired(uint256 indexed txId);
    event TransactionStateChanged(uint256 indexed txId, TransactionState newState);
    event InsufficientApprovals(uint256 indexed txId, uint256 approvals);

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
        signerFunctions[PAUSE_SELECTOR] = true;
        signerFunctions[UNPAUSE_SELECTOR] = true;
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
    function _updateTransactionState(uint256 txId) public txExist(txId) returns (TransactionState) {
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

    /**
     * @notice Creates a standard transaction or calls it if sender is superAdmin
     * @param _selector The function selector for the transaction
     * @param _params The parameters to pass with the transaction
     * @return The timestamp of the transaction
     */
    function _createStandardTransaction(bytes4 _selector, bytes memory _params) private returns (uint256) {
        if (_msgSender() == superAdmin()) {
            _call(_selector, _params);
            return block.timestamp;
        }
        return createTransaction(_selector, _params);
    }

    /**
     * @notice Creates a mint transaction
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     * @return The transaction ID
     */
    function createMintTransaction(address to, uint256 amount) external virtual notZeroAddress(to) returns (uint256) {
        return _createStandardTransaction(MINT_SELECTOR, abi.encode(to, amount));
    }

    /**
     * @notice Creates a burn transaction
     * @param from The address from which to burn tokens
     * @param amount The amount of tokens to burn
     * @return The transaction ID
     */
    function createBurnTransaction(address from, uint256 amount)
        external
        virtual
        notZeroAddress(from)
        returns (uint256)
    {
        return _createStandardTransaction(BURN_SELECTOR, abi.encode(from, amount));
    }

    /**
     * @notice Creates a transaction to blacklist an account
     * @param account The account to blacklist
     * @return The transaction ID
     */
    function createBlacklistAccountTransaction(address account)
        external
        virtual
        notZeroAddress(account)
        returns (uint256)
    {
        return _createStandardTransaction(BLACKLIST_ACCOUNT_SELECTOR, abi.encode(account));
    }

    /**
     * @notice Creates a transaction to remove an account from the blacklist
     * @param account The account to remove from the blacklist
     * @return The transaction ID
     */
    function createBlacklistRemoveTransaction(address account)
        external
        virtual
        notZeroAddress(account)
        returns (uint256)
    {
        return _createStandardTransaction(REMOVE_BLACKLIST_ACCOUNT_SELECTOR, abi.encode(account));
    }

    /**
     * @notice Creates a pause transaction
     * @return The transaction ID
     */
    function createPauseTransaction() external virtual returns (uint256) {
        return _createStandardTransaction(PAUSE_SELECTOR, "");
    }

    /**
     * @notice Creates an unpause transaction
     * @return The transaction ID
     */
    function createUnpauseTransaction() external virtual returns (uint256) {
        return _createStandardTransaction(UNPAUSE_SELECTOR, "");
    }

    /**
     * @notice Creates a transaction to recover tokens
     * @param token The token address
     * @param to The address to send the recovered tokens
     * @return The transaction ID
     */
    function createRecoverTokensTransaction(address token, address to)
        external
        virtual
        notZeroAddress(token)
        notZeroAddress(to)
        returns (uint256)
    {
        return _createStandardTransaction(RECOVER_TOKENS_SELECTOR, abi.encode(token, to));
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
    function approveTransaction(uint256 txId) external virtual txExist(txId) {
        if (!isSigner(_msgSender())) revert UnauthorizedCall();
        if (hasApproved[txId][_msgSender()]) revert AlreadyApproved();

        Transaction storage transaction = transactions[txId];
        TransactionState currentState = _updateTransactionState(txId);

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
        _updateTransactionState(txId);
    }

    /**
     * @notice Revokes a previously approved transaction
     * @param txId The transaction ID to revoke
     */
    function revokeTransaction(uint256 txId) external virtual txExist(txId) {
        if (!isSigner(_msgSender())) revert UnauthorizedCall();
        if (!hasApproved[txId][_msgSender()]) revert TransactionNotSigned();

        Transaction storage transaction = transactions[txId];
        TransactionState currentState = _updateTransactionState(txId);

        if (currentState != TransactionState.Active) {
            revert InvalidState();
        }
        unchecked {
            transaction.approvals -= 1;
        }
        hasApproved[txId][_msgSender()] = false;

        emit TransactionRevoked(txId, _msgSender());

        _updateTransactionState(txId);
    }

    /**
     * @notice Executes a transaction if it has enough approvals
     * @param txId The transaction ID to execute
     */
    function executeTransaction(uint256 txId) external virtual txExist(txId) {
        Transaction storage transaction = transactions[txId];
        TransactionState currentState = _updateTransactionState(txId);

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
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            z := xor(x, mul(xor(x, y), lt(y, x)))
        }
    }

    /**
     * @notice Adds a function to fallback admin permissions
     * @param functionSelector The function selector to add
     */
    function addFallbackAdminFunctions(bytes4 functionSelector) external {
        if (_msgSender() != superAdmin()) {
            revert UnauthorizedCall();
        }
        if (fallbackAdminFunctions[functionSelector]) {
            revert FunctionAlreadyExists();
        }
        fallbackAdminFunctions[functionSelector] = true;
    }

    /**
     * @notice Adds a function to signer permissions
     * @param functionSelector The function selector to add
     */
    function addSignerFunctions(bytes4 functionSelector) external {
        if (_msgSender() != superAdmin()) {
            revert UnauthorizedCall();
        }
        if (signerFunctions[functionSelector]) {
            revert FunctionAlreadyExists();
        }
        signerFunctions[functionSelector] = true;
    }

    /**
     * @notice Removes a function from fallback admin permissions
     * @param functionSelector The function selector to remove
     */
    function removeFallbackAdminFunction(bytes4 functionSelector) external {
        if (_msgSender() != superAdmin()) {
            revert UnauthorizedCall();
        }
        if (!fallbackAdminFunctions[functionSelector]) {
            revert FunctionDoesNotExist();
        }
        fallbackAdminFunctions[functionSelector] = false;
    }

    /**
     * @notice Removes a function from signer permissions
     * @param functionSelector The function selector to remove
     */
    function removeSignerFunction(bytes4 functionSelector) external {
        if (_msgSender() != superAdmin()) {
            revert UnauthorizedCall();
        }
        if (!signerFunctions[functionSelector]) {
            revert FunctionDoesNotExist();
        }
        signerFunctions[functionSelector] = false;
    }
}
