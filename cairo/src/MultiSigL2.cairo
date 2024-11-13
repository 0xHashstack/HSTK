
// use starknet::{ContractAddress,ClassHash};
// #[derive(Copy, Drop, Serde, starknet::Store)]
// pub enum TransactionState {
//     Pending,
//     Active,
//     Queued,
//     Expired,
//     Executed,
// }


// #[starknet::interface]
// pub trait IMultiSigL2<TContractState> {
//     fn upgrade(ref self: TContractState, new_class_hash: ClassHash);
//     fn create_blacklist_tx(ref self:TContractState, account:ContractAddress)->felt252;
//     fn create_removeBlacklisted_tx(ref self:TContractState, account:ContractAddress)->felt252;
//     fn create_recover_token_tx(ref self: TContractState,asset:ContractAddress, receipient:ContractAddress)->felt252;
//     fn update_pauseState_tx(ref self:TContractState,state:u8)->felt252;
//     fn update_transaction_state(ref self:TContractState,tx_id:felt252)->TransactionState;
//     fn approve_transaction(ref self: TContractState,tx_id:felt252);
//     fn revoke_signatory(ref self: TContractState,tx_id:felt252);
//     fn execute_transaction(ref self: TContractState,tx_id:felt252);
//     fn is_valid_tx(self:@TContractState,tx_id:felt252)->bool;
// }


// #[starknet::contract]
// pub mod MultiSigL2{

//     use starknet::{ContractAddress,ClassHash,SyscallResultTrait};
//     use starknet::{get_caller_address,get_block_timestamp};
//     use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
//     use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
//     use core::array::ArrayTrait;
//     use core::option::OptionTrait;
//     use cairo::components::AccessRegistry::AccessRegistryComp;
//     use cairo::components::SuperAdmin2Step::SuperAdminTwoStep;
//     use openzeppelin::upgrades::{UpgradeableComponent, interface::IUpgradeable};
//     use openzeppelin::introspection::src5::SRC5Component;
//     use super::TransactionState;
//     use core::num::traits::Zero;
//     use starknet::StorageBaseAddress;
//     use core::pedersen::PedersenTrait;
//     use starknet::account::Call;
//     use starknet::syscalls::call_contract_syscall;

//     component!(path: SuperAdminTwoStep , storage: super_admin_two_step , event: SuperAdminTwoStepEvents);
//     component!(path: AccessRegistryComp , storage: access_registry , event: AccessRegistryEvents);
//     component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
//     component!(path: SRC5Component, storage: src5, event: SRC5Event);


//     // impl UpgradeableInternalImpl = UpgradeableComponent::In<ContractState>;
//     // impl AccessControlInternalImpl = AccessRegistryComp::AccessRegistyImpl<ContractState>;

//      // Constants
//     pub const SIGNER_WINDOW: u64 = 86400; // 24 hours in seconds
//     pub const APPROVAL_THRESHOLD: u64 = 60; // 60% of signers must approve
 
//      // Function selectors as constants
//     pub const PAUSE_STATE_SELECTOR: felt252 = selector!("update_pause_state(u8)");
//     pub const BLACKLIST_ACCOUNT_SELECTOR: felt252 = selector!("blacklist_account(ContractAddress)");
//     pub const REMOVE_BLACKLIST_ACCOUNT_SELECTOR: felt252 = selector!("remove_blacklisted(ContractAddress)");
//     pub const RECOVER_TOKENS_SELECTOR: felt252 = selector!("recover_tokens(ContractAddress,ContractAddress)");

//     #[derive(Drop, Serde, starknet::Store)]
//     pub struct Transaction {
//         proposer: ContractAddress,
//         selector: felt252,
//         params : Span<felt252>,
//         proposed_at: u64,
//         first_sign_at: u64,
//         approvals: u64,
//         state: TransactionState
//     }

//     #[storage]
//     pub struct Storage {
//         #[substorage(v0)]
//         super_admin_two_step:SuperAdminTwoStep::Storage,
//         #[substorage(v0)]
//         access_registry:AccessRegistryComp::Storage,
//         #[substorage(v0)]
//         upgradeable: UpgradeableComponent::Storage,
//         #[substorage(v0)]
//         src5: SRC5Component::Storage,
//         token_contract: ContractAddress,
//         transactions: LegacyMap<felt252, Transaction>,
//         has_approved: LegacyMap<(felt252, ContractAddress), bool>,
//         transaction_exists: LegacyMap<felt252, bool>,
//         signer_functions: LegacyMap<felt252, bool>
      

//     }

//     #[event]
//     #[derive(Drop,starknet::Event)]
//     pub enum Event{
//         TransactionProposed: TransactionProposed,
//         TransactionApproved: TransactionApproved,
//         SignatoryRevoked: SignatoryRevoked,
//         TransactionExecuted: TransactionExecuted,
//         TransactionExpired: TransactionExpired,
//         TransactionStateChanged: TransactionStateChanged,
//         #[flat]
//         SuperAdminTwoStepEvents: SuperAdminTwoStep::Event,
//         #[flat]
//         AccessRegistryEvents: AccessRegistryComp::Event,
//         #[flat]
//         UpgradeableEvent: UpgradeableComponent::Event,
//         #[flat]
//         SRC5Event: SRC5Component::Event
//     }

//     #[derive(Drop,starknet::Event)]
//     pub struct TransactionProposed {
//         #[key]
//         pub tx_id: felt252,
//         #[key]
//         pub proposer:ContractAddress,
//         #[key]
//         pub proposed_at: u64,
//     }

//     #[derive(Drop,starknet::Event)]
//     pub struct TransactionApproved {
//         #[key]
//         pub tx_id: felt252,
//         #[key]
//         pub signer: ContractAddress,
//     }

//     #[derive(Drop,starknet::Event)]
//     pub struct SignatoryRevoked {
//         #[key]
//         pub tx_id: felt252,
//         #[key]
//         pub revoker: ContractAddress,
//     }

//     #[derive(Drop,starknet::Event)]
//     pub struct TransactionExecuted {
//         #[key]
//         pub tx_id: felt252
//     }

//     #[derive(Drop,starknet::Event)]
//     pub struct TransactionExpired {
//         #[key]
//         pub tx_id: felt252
//     }

//     #[derive(Drop,starknet::Event)]
//     pub struct TransactionStateChanged {
//         #[key]
//         pub tx_id: felt252,
//         #[key]
//         pub new_state: TransactionState,
//     }

//     pub mod Error{
//         pub const ZERO_ADDRESS:felt252 = 'CAlldata consist Zero Address';
//     }

//     #[abi(embed_v0)]
//     impl AccessControlImpl =
//     AccessRegistryComp::AccessControlImpl<ContractState>;

//     #[abi(embed_v0)]
//     impl SuperAdminTwoStepImpl =
//         SuperAdminTwoStep::SuperAdminTwoStepImpl<ContractState>;

//     #[constructor]
//     fn constructor(ref self: ContractState,token_l2:ContractAddress, super_admin:ContractAddress){
//         assert(!token_l2.is_zero() && !super_admin.is_zero(),Error::ZERO_ADDRESS);
//         self.access_registry.initializer(super_admin);
//         self.token_contract.write(token_l2);
//     }

//     impl MultiSigL2Impl of super::IMultiSigL2<ContractState>{

//         fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
//             self.access_registry.assert_only_super_admin();
//             self.upgradeable._upgrade(new_class_hash);
//         }

//         fn create_blacklist_tx(ref self:ContractState, account:ContractAddress)->felt252 {

//             assert(!account.is_zero(),Error::ZERO_ADDRESS);
//             assert(!self.access_registry.is_signer(get_caller_address()),'Not Signer');
//             let calldata:Span<felt252> = array![account.into()];
//             self._route_standarad_transaction(BLACKLIST_ACCOUNT_SELECTOR,calldata)
//         }
//         fn create_removeBlacklisted_tx(ref self:ContractState, account:ContractAddress)->felt252{

//             assert(!account.is_zero(),Error::ZERO_ADDRESS);
//             assert(!self.access_registry.is_signer(get_caller_address()),'Not Signer');
//             let calldata:Span<felt252> = array![account.into()];
//             self._route_standarad_transaction(REMOVE_BLACKLIST_ACCOUNT_SELECTOR,calldata)

//         }
//         fn create_recover_token_tx(ref self: ContractState,asset:ContractAddress, receipient:ContractAddress)->felt252{

//             assert(!asset.is_zero() &&!receipient.is_zero() ,Error::ZERO_ADDRESS);
//             assert(!self.access_registry.is_signer(get_caller_address()),'Not Signer');
//             let calldata:Span<felt252> = array![asset.into(),receipient.into()];
//             self._route_standarad_transaction(RECOVER_TOKENS_SELECTOR,calldata)

//         }
//         fn update_pauseState_tx(ref self:ContractState,state:u8)->felt252{

//             assert(!self.access_registry.is_signer(get_caller_address()),'Not Signer');
//             let calldata:Span<felt252> = array![state.into()];
//             self._route_standarad_transaction(PAUSE_STATE_SELECTOR,calldata)

//         }
//         fn update_transaction_state(ref self:ContractState,tx_id:felt252)->TransactionState{
//             self._assert_transaction_exists(tx_id);
//             let mut transaction:Transaction = self.transactions.read(tx_id);

//             if(transaction.state == TransactionState.Expired || transaction.state == TransactionState.Executed){
//                 transaction.state
//             }
//             let current_time = get_block_timestamp();
            
//             let isExpired:bool = current_time > transaction.first_sign_at + SIGNER_WINDOW;

//             let new_state:TransactionState = transaction.state;
//             let total_signers:u64 = self.access_registry.total_signers();

//             if(isExpired){
//                 if((transaction.approvals * 100) / totalSigner >= APPROVAL_THRESHOLD){
//                     new_state = TransactionState.Queued;
//                 }else{
//                     //emit an Insufficient Approval Event
//                     self.emit(
//                         TransactionExpired{
//                             tx_id: tx_id
//                         }
//                     );
//                     new_state = TransactionState.Expired;
//                 }
//             }else if(transaction.first_sign_at!=0){
//                 new_state = TransactionState.Active;
//             }

//             if (new_state != transaction.state) {
//                 transaction.state = newState;
//                 // self.(emit{TransactionStateChanged(txId, transaction.state)});
//             }
    
//             newState
           
//         }
//         fn is_valid_tx(self:@ContractState,tx_id:u256)->bool{
//             true
//         }

//         fn approve_transaction(ref self: ContractState, tx_id: felt252) {

//                 self._assert_transaction_exists(tx_id);
//                 let caller = get_caller_address();
//                 let current_timestamp =get_block_timestamp();
//                 assert(self.access_registry.is_signer(caller), 'Not a signer');
//                 assert(!self.has_approved.read((tx_id, caller)), 'Already approved');
    
//                 let mut transaction = self.transactions.read(tx_id);
//                 let current_state = self.update_transaction_state(tx_id);
                
//                 assert(
//                     current_state == TransactionState::Pending || 
//                     current_state == TransactionState::Active,
//                     'Invalid state'
//                 );
    
//                 if transaction.approvals == 0 {
//                     transaction.first_sign_at = current_timestamp;
//                 }
                
//                 transaction.approvals += 1;
//                 self.has_approved.write((tx_id, caller), true);
//                 self.transactions.write(tx_id, transaction);
    
//                 self.emit(TransactionApproved { tx_id, signer: caller });
//         }
//         fn revoke_signatory(ref self: ContractState,tx_id:felt252){

//             self._assert_transaction_exists(tx_id);
//                 let caller = get_caller_address();
//                 let current_timestamp =get_block_timestamp();
//                 assert(self.access_registry.is_signer(caller), 'Not a signer');
//                 assert(self.has_approved.read((tx_id, caller)), 'Not approved');
    
//                 let mut transaction = self.transactions.read(tx_id);
//                 let current_state:TransactionState = self.update_transaction_state(tx_id);
                
//                 assert( 
//                     current_state == TransactionState::Active,
//                     'Invalid state for Revoke Signature'
//                 );
//                 transaction.approvals -= 1;
//                 self.has_approved.write((tx_id, caller), false);
//                 self.transactions.write(tx_id, transaction);
//                 self.emit(SignatoryRevoked { tx_id, signer: caller });


//         }
//         fn execute_transaction(ref self: ContractState, tx_id: felt252) {
//             self._assert_transaction_exists(tx_id);
//             let mut transaction = self.transactions.read(tx_id);
//             let current_state = self.update_transaction_state(tx_id);

//             assert(current_state == TransactionState::Queued, 'Invalid state');
//             transaction.state = TransactionState::Executed;
//             self.transactions.write(tx_id, transaction);

//             self._call(transaction.selector, transaction.params);
//             self.emit(TransactionExecuted { tx_id });
//         }

//     }
//     #[generate_trait]
//     impl InternalImpl of InternalTrait {
//         fn _route_standarad_transaction(ref self: ContractState, function_selector: felt252 , calldata:Array<felt252>)->felt252{
//             let caller: ContractAddress = get_caller_address();
//             let super_admin:ContractAddress = self.super_admin_two_step.super_admin();
//             if(caller==super_admin){
//                 self._call(function_selector,calldata)
//             }else{
//                 self._create_transaction(function_selector,calldata)
//             }

//         }

//         fn _assert_transaction_exists(ref self: ContractState, tx_id: felt252) {
//             assert(self.transaction_exists.read(tx_id), 'Transaction not found');
//         }

//         fn _create_transaction(
//             ref self: ContractState,
//             selector: felt252,
//             params: Span<felt252>
//             ) -> felt252 {
//                 let caller = get_caller_address();
//                 let is_signer = self.access_registry.is_signer(caller);
//                 let timestamp = get_block_timestamp();
//                 let is_valid_function:bool = self.signer_functions.read(selector);
    
//                 assert(is_valid_function && is_signer , 'Unauthorized');

//                 let tx_id = PedersenTrait::new(0).update_with(params).update_with(timestamp).update_with(selector).finalize();


//                 //For multiple transaction with same params andd calldata in a single Block.
//                 assert(!self.transaction_exists.read(tx_id), 'Transaction exists');
    
//                 self.transaction_exists.write(tx_id, true);
//                 let transaction:Transaction = Transaction {
//                     proposer: caller,
//                     selector,
//                     params,
//                     proposed_at: timestamp,
//                     first_sign_at: 0,
//                     approvals: 0,
//                     state: TransactionState::Pending
//                 };
    
//                 self.transactions.write(tx_id, transaction);
//                 self.emit(TransactionProposed { 
//                     tx_id,
//                     proposer: caller,
//                     proposed_at: get_block_timestamp()
//                 });
    
//                 tx_id
//             }

//         fn _call(self:@ContractState, function_selector:felt252, calldata:Array<felt252>)->felt252{
//             get_block_timestamp().into()

//         }


//         // const PAUSE_STATE_SELECTOR: felt252 = selector!("update_pause_state(u8)");
//         // const BLACKLIST_ACCOUNT_SELECTOR: felt252 = selector!("blacklist_account(ContractAddress)");
//         // const REMOVE_BLACKLIST_ACCOUNT_SELECTOR: felt252 = selector!("remove_blacklisted(ContractAddress)");
//         // const RECOVER_TOKENS_SELECTOR: felt252 = selector!("recover_tokens(ContractAddress,ContractAddress)");
    

//     }

// }
