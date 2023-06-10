// Copyright (c) 2023, Vivid Network Contributors
// SPDX-License-Identifier: Apache-2.0

module suiswap::TOKEN {
    use std::vector;
    use sui::math;
    use sui::transfer;
    use sui::coin::{Self, Coin, TreasuryCap};
    use std::option::{ Self, Option };
    use std::ascii;
    use sui::event;
    use sui::url;
    use sui::bcs;
    use sui::ed25519::{ ed25519_verify };
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::table::{ Self, Table };
    use sui::dynamic_field::{ Self as df };
    use suiswap::utils::{ Self };
    use sui::sui::SUI;
    use sui::clock::Clock;
    use suiswap::ratio::{ Self, Ratio };
    use suiswap::sbalance:: { Self as sb, SBalance };
    use suiswap::permission:: { Self, Permission };

    friend suiswap::pool;

    const VERSION: u64 = 0;
    
    const TOKEN_MAX_SUPPLY: u64 = 10000000000000000000;

    // The early unlock token fee 10%
    const Config_EarlyUnlockTokenFeeNumerator: u64 = 1000;
    const Config_EarlyUnlockTokenFeeDenominator: u64 = 10000;
 
    /// For when supplied Coin is zero.
    const ETokenInvalidParameter: u64 = 14400;
    /// Not enough balance for operation
    const ETokenNotEnoughBalance: u64 = 144001;
    /// Token has already airdropped
    const ETokenAirdropHasAlreadyAirdropped: u64 = 144002;
    /// Cannot pass the verification process of the airdrop
    const ETokenAirdropVerificationFailed: u64 = 144003;
    /// Cannot add the whitelist since it is closed for adding whitelist members
    const ETokenIdoWhitelistMemberNotOpenToAdd: u64 = 144004;
    /// Cannot not buy ido due to is not public and you are not in the whitelist
    const ETokenIdoCannotBuyPermissionDenied: u64 = 144005;
    /// The target output buying token is over the current left balance in the IDO
    const ETokenIdoCannotBuyOutOfLeftBalance: u64 = 144006;
    /// The stake epoch has ended so we cannot early unlock the stake token, just unlock it normally
    const ETokenEarlyUnlockStakeTokenEpochError: u64 = 144007;
    /// The invalid stake token time (index) for staking a token
    const ETokenInvalidStakeIndex: u64 = 144008;
    /// There's no enough balance in the bank for creating the staked token
    const ETokenCannotStakeNotEnoughBankBalance: u64 = 144009;
    /// Cannot unlock the token, not started yet 
    const ETokenCannotUnlockStakeTokenNotStarted: u64 = 144010;
    /// Cannot destroy stake token that have value in it
    const ETokenCannotDestoryHaveValueStakedToken: u64 = 144011;
    /// Cannot stake the token, current stake index is less than the min stake inedx
    const ETokenStakeIndexLessThanTheMinStakeIndex: u64 = 144012;
    /// Cannot early unlock the token, current epoch is less than the start epoch
    const ETokenEarlyUnlockStakeTokenNotStarted: u64 = 144013;
    /// Maximum supply overflow
    const ETokenOverMaxSupply: u64 = 144014;
    /// No implementeed error code
    const ETokenNoImplement: u64 = 144040;
    /// Deprecated
    const ETokenDeprecated: u64 = 144041;

    /// Not correct version
    const EVersionNotMatched: u64 = 200000;

    const C_1E9_U128: u128 = 1000000000;
    const C_1E9_U64: u64 = 1000000000;

    /// The platform token
    struct TOKEN has drop { }

    /// The representation of the token that staked in the protocol
    struct StakedToken has key, store {
        /// The id of the stake token
        id: UID,
        /// The balance in the staked token
        balance: SBalance<TOKEN>,
        /// The profit in the staked token
        profit: SBalance<TOKEN>,
        /// The start epoch for staking
        start_epoch: u64,
        /// The end epoch for staking
        end_epoch: u64,
        /// The boost (amount * multiplier) for current reward
        boost: u128
    }

    public(friend) fun staked_token_add_data<Name: copy + drop + store, Value: store>(st: &mut StakedToken, name: Name, value: Value) {
        df::add<Name, Value>(&mut st.id, name, value)
    }

    public(friend) fun staked_token_pop_data<Name: copy + drop + store, Value: store>(st: &mut StakedToken, name: Name): Option<Value> {
        df::remove_if_exists<Name, Value>(&mut st.id, name)
    }

    public fun staked_token_get_id(x: &StakedToken): ID { object::uid_to_inner(&x.id) }
    public fun staked_token_get_origin_balance_value(x: &StakedToken): u64 { sb::supply(&x.balance) }
    public fun staked_token_get_origin_profit_value(x: &StakedToken): u64 { sb::supply(&x.profit) }
    public fun staked_token_get_left_balance_value(x: &StakedToken): u64 { sb::value(&x.balance) }
    public fun staked_token_get_left_profit_value(x: &StakedToken): u64 { sb::value(&x.profit) }
    public fun staked_token_get_boost(x: &StakedToken): u128 { x.boost }
    public fun staked_token_get_start_epoch(x: &StakedToken): u64 { x.start_epoch }
    public fun staked_token_get_end_epoch(x: &StakedToken): u64 { x.end_epoch }
    // public(friend) fun staked_token_inc_end_epoch(x: &mut StakedToken, v: u64) { x.end_epoch = x.end_epoch + v; }

    /// Representation of the staked token that can linear unlock
    struct LinearUnlockStakedToken has key {
        /// The id of the stake token
        id: UID,
        /// The origin id for initial creation
        origin_id: ID,
        /// The actual data structure
        inner: StakedToken
    }

    public fun linear_staked_token_get_id(x: &LinearUnlockStakedToken): ID { object::uid_to_inner(&x.id) }
    public fun linear_staked_token_get_origin_balance_value(x: &LinearUnlockStakedToken): u64 { sb::supply(&x.inner.balance) }
    public fun linear_staked_token_get_origin_profit_value(x: &LinearUnlockStakedToken): u64 { sb::supply(&x.inner.profit) }
    public fun linear_staked_token_get_left_balance_value(x: &LinearUnlockStakedToken): u64 { sb::value(&x.inner.balance) }
    public fun linear_staked_token_get_left_profit_value(x: &LinearUnlockStakedToken): u64 { sb::value(&x.inner.profit) }
    public fun linear_staked_token_get_start_epoch(x: &LinearUnlockStakedToken): u64 { x.inner.start_epoch }
    public fun linear_staked_token_get_end_epoch(x: &LinearUnlockStakedToken): u64 { x.inner.end_epoch }

    const TokenBankPublicKey_Slot: u64 = 0;

    /// A global storage for all the tokens
    struct TokenBank has key {
        /// The id of the token bank
        id: UID,
        /// The version of the object
        version: u64,
        /// The owner of the token bank, used to retrive bank value based on the sign of the owner
        owner: address,
        /// The current balance storage in the bank
        balance: SBalance<TOKEN>,
        /// A chunk for holding some token by admin. Normally when a user try to claim staked token before the ending epoch 
        /// or other operations. They will generate admin_balance that admin redeem
        admin_balance: Balance<TOKEN>,
        /// The early unlcok staked token fee
        early_unlock_fee: Ratio,
        /// The statistics of total token that has been liquidity mined
        stats_liquidity_mine_amount: u64,
        /// The ids of the created token farm
        token_farm_ids: vector<ID>,
        /// The ids of the created token ido
        token_ido_ids: vector<ID>,
        /// The ids of the created token airdrop
        token_airdrop_ids: vector<ID>,
    }
    public fun token_bank_get_id(x: &TokenBank): ID { object::uid_to_inner(&x.id) }
    public fun token_bank_get_owner(x: &TokenBank): address { x.owner }
    public fun token_bank_get_supply(x: &TokenBank): u64 { sb::supply(&x.balance) }
    public fun token_bank_get_balance_value(x: &TokenBank): u64 { sb::value(&x.balance) }
    public fun token_bank_get_public_key(x: &TokenBank): Option<vector<u8>> {
        if (df::exists_with_type<u64, vector<u8>>(&x.id, TokenBankPublicKey_Slot)) {
            let pks = df::borrow<u64, vector<u8>>(&x.id, TokenBankPublicKey_Slot);
            option::some(*pks)
        }
        else {
            option::none()
        }
    }

    /// Represents a token airdrop struct to store information for adirdrop needed
    struct TokenAirdrop has key {
        /// The id of the token bank
        id: UID,
        /// The version of the token airdrop
        version: u64,
        /// The verifity ID, user can assigned a special one or use `id` as `verifity_id` to append additional airdrop information for verification
        verify_id: ID,
        /// The public key to verify the signature verification (ed25519)
        public_key: vector<u8>,
        /// The id of the bank
        bank_id: ID,
        /// The owner of the airdrop
        owner: address,
        /// When free amount is not 0, indicating it is a free airdrop (which people can get airdrop without sending any proof for that)
        free_amount: u64,
        /// The name of the airdrop, should be a 16-bytes-long-char, normamly some meaningful message
        name: vector<u8>,
        /// Use to check whether we have airdropped to an address already
        address_table: Table<address, u8>,
        /// The balance inside the airdrop
        balance: SBalance<TOKEN>,
        /// Whether the airdrop allow duplicate for checking
        allow_duplicate: bool
    }

    public fun token_airdrop_get_id(x: &TokenAirdrop): ID { object::uid_to_inner(&x.id) }
    public fun token_airdrop_get_bank_id(x: &TokenAirdrop): ID { x.bank_id }
    public fun token_airdrop_get_owner(x: &TokenAirdrop): address { x.owner }
    public fun token_airdrop_get_free_amount(x: &TokenAirdrop): u64 { x.free_amount }
    public fun token_airdrop_get_name(x: &TokenAirdrop): vector<u8> { x.name }
    public fun token_airdrop_get_balance_value(x: &TokenAirdrop): u64 { sb::value(&x.balance) }
    public fun token_airdrop_get_supply(x: &TokenAirdrop): u64  { sb::supply(&x.balance) }
    public fun token_airdrop_is_free(x: &TokenAirdrop): bool { x.free_amount > 0 }
    /// Check whether we have airdropped to one specified address
    public fun token_airdrop_has_used_address(x: &TokenAirdrop, addr: address): bool {
        table::contains(&x.address_table, addr)
    }

    const TOKEN_STAKE_PROFIT_SCALING: u64 = 10000;
    const TOKEN_STAKE_DEFAULT_BOOST_VALUE: u64 = 10;

    struct TokenFarmIndexValue has copy, drop, store {
        /// The profit value for staking, scaling by TOKEN_STAKE_PROFIT_SCALING
        profit: u64,
        /// The boost value for stking, representing the multiplier to the reward
        boost_multiplier: u64,
    }
    public fun token_farm_index_value_get_profit(x: &TokenFarmIndexValue): u64 { x.profit }
    public fun token_farm_index_value_get_boost(x: &TokenFarmIndexValue): u64 { x.boost_multiplier }

    struct TokenFarm has key {
        /// The id of the token stake
        id: UID,
        /// The version of the token farm,
        version: u64,
        /// The bank id of the token stake
        bank_id: ID,
        /// Treat as a multiplier to the profit table
        base_epochs: u64,
        /// The minimum staking index, so that user could not stake less than current index
        min_stake_index: u64,
        /// The key is the index and the value is the info for staking at current index. 
        /// The actual epoch should be computed by the `index * base_epochs`.
        /// For example, when index is 6 and base_epochs is 30 (a month normally) and the value of the index in `stake_index_table` is 700, then
        /// it means for roughly 6 months (since 1 epoch equals to 1 day) you stake 100 TOKEN and you will get 107 TOKEN for returns. 
        stake_index_table: Table<u64, TokenFarmIndexValue>,
        /// The total staking amount in the farm
        total_stake_amount: u64,
        /// The total staking boost in the farm
        total_stake_boost: u128,
    }

    public fun token_farm_get_id(x: & TokenFarm): ID { object::uid_to_inner(&x.id) }
    public fun token_farm_get_bank_id(x: & TokenFarm): ID { x.bank_id }
    public fun token_farm_get_base_epochs(x: & TokenFarm): u64 { x.base_epochs }
    public fun token_farm_has_index_in_stake_index_table(x: & TokenFarm, index: u64): bool { table::contains(&x.stake_index_table, index) }
    public fun token_farm_get_value_for_index(x: & TokenFarm, index: u64): TokenFarmIndexValue { *table::borrow(&x.stake_index_table, index) }
    public fun token_farm_get_total_stake_amount(x: &TokenFarm): u64 { x.total_stake_amount }
    public fun token_farm_get_total_stake_boost(x: &TokenFarm): u128 { x.total_stake_boost }

    /// Represents a ido token event
    const TOKEN_IDO_PRICE_SCALING: u128 = 1000000000;
    struct TokenIdo has key {
        /// The id of the token ido event
        id: UID,
        /// The version of the object
        version: u64,
        /// The bank ID of the ido
        bank_id: ID,
        /// The name of the ido event
        name: vector<u8>,
        /// The price of the ido, relative to SUI, in e9 format, which means when price_e9 = 10^9, 1 unit of token is selled by 1 SUI (MIST)
        price_e9: u64,
        /// Inidicating whether the ido is public, if not, only the members in the whitelist can participate
        is_public: bool,
        /// The whitelist members, only those address members could participate the ido when `is_public` is set to false
        whitelists: Table<address, u8>,
        /// Indicating the whitelist is currently editable
        is_whitelists_editable: bool,
        /// The collect SUI token in the IDO
        collect: Balance<SUI>,
        /// Currently holding token 
        balance: SBalance<TOKEN>,
    }

    public fun token_ido_get_id(x: &TokenIdo): ID { object::uid_to_inner(&x.id) }
    public fun token_ido_get_bank_id(x: &TokenIdo): ID { x.bank_id }
    public fun token_ido_get_name(x: &TokenIdo): vector<u8> { x.name }
    public fun token_ido_get_price_e9(x: &TokenIdo): u64 { x.price_e9 }
    public fun token_ido_get_is_public(x: &TokenIdo): bool { x.is_public }
    public fun token_ido_get_is_whitelists_editable(x: &TokenIdo): bool { x.is_whitelists_editable }
    public fun token_ido_get_collect_value(x: &TokenIdo): u64 { balance::value(&x.collect) }
    public fun token_ido_get_balance_value(x: &TokenIdo): u64 { sb::value(&x.balance) }
    public fun token_ido_get_supply(x: &TokenIdo): u64 { sb::supply(&x.balance) }
    /// Check whether the token ido has the whitelist address
    public fun token_ido_is_public_or_has_whitelist_address(x: &TokenIdo, addr: address): bool {
        if (x.is_public) { true } else { table::contains(&x.whitelists, addr) }
    }

    // Used to change the verfity id
    // fun token_airdrop_change_verify_id(x: &mut TokenAirdrop, id: ID) {
    //     x.verify_id = id;
    // }

    struct TokenCap has key {
        /// The id of the token cap
        id: UID,
        /// The treasury cap for the Suiswap Token
        treasury_cap: TreasuryCap<TOKEN>,
        /// The permission of TokenBank
        token_bank_permission: Permission<TokenBank>,
        /// The permission of ToeknAirdrop
        token_airdrop_permission: Permission<TokenAirdrop>,
        /// The permission of TokenFarm
        token_farm_permission: Permission<TokenFarm>,
        /// The permission of TokenIdo
        token_ido_permission: Permission<TokenIdo>,
        /// The token bank id reference
        bank_id: ID,
        /// The address id
        coin_metadata_id: ID,
    }
    public fun token_cap_cp_token_bank_permission(cap: &TokenCap): Permission<TokenBank>  { permission::cp(&cap.token_bank_permission) }
    public fun token_cap_cp_token_airdrop_permission(cap: &TokenCap): Permission<TokenAirdrop> { permission::cp(&cap.token_airdrop_permission) }
    public fun token_cap_cp_token_farm_permission(cap: &TokenCap): Permission<TokenFarm> { permission::cp(&cap.token_farm_permission) }
    public fun token_cap_cp_token_ido_permission(cap: &TokenCap): Permission<TokenIdo> { permission::cp(&cap.token_ido_permission) }

    struct IncreaseTokenSupplyEvent has copy, drop {
        /// The bank id
        bank_id: ID,
        /// Amount
        amount: u64
    }

    const ESendTokenEvent_TokenType_Token: u8 = 0;
    const ESendTokenEvent_TokenType_StakedToken: u8 = 1;
    const ESendTokenEvent_TokenType_LineraUnlockStakedToken: u8 = 2;
    struct SendTokenEvent has copy, drop { 
        /// The id of the token
        token_id: ID,
        /// The bank id
        bank_id: ID,
        /// Amount
        amount: u64,
        /// Receipient
        recipient: address,
        /// The type of the token, 0 for general token, 1 for staked token, 2 for linear unlock staked token
        token_type: u8,
    }

    struct WithdarwTokenBankAdminBalance has store, copy, drop {
        amount: u64    
    }

    struct ClaimTokenAirdropEvent has copy, drop {
        /// The id of token airdrop
        airdrop_id: ID,
        /// The amount of the airdrop
        amount: u64,
    }

    struct AddTokenIdoWhitelistEvent has copy, drop {
        /// The id of the ido
        ido_id: ID,
    }

    struct BuyTokenIdoTokenEvent has copy, drop {
        /// The id of the ido
        ido_id: ID,
        /// The in amount
        in_amount: u64,
        /// The out amount
        out_amount: u64
    }

    struct StakeTokenEvent has copy, drop {
        /// The id of the staked token
        st_id: ID,
    }

    struct UnlockStakeTokenEvent has copy, drop {
        /// The id of the staked token
        st_id: ID,
    }

    struct UnwrapLinearUnlockStakedTokenEvent has copy, drop {
        /// The id of the staked token
        st_id: ID
    }

    // ============================================= API =============================================

    fun init(witness: TOKEN, ctx: &mut TxContext) { init_impl(witness, ctx) }

    public entry fun increase_token_supply(cap: &mut TokenCap, bank: &mut TokenBank, amount: u64, ctx: &mut TxContext) {
        do_increase_token_supply(cap, bank, amount, ctx);
    }

    public entry fun withdraw_token_bank_admin_balance(cap: &TokenCap, bank: &mut TokenBank, ctx: &mut TxContext) {
        do_withdraw_token_bank_admin_balance(&cap.token_bank_permission, bank, ctx);
    }

    public entry fun send_token(cap: &TokenCap, bank: &mut TokenBank, amount: u64, recipient: address, ctx: &mut TxContext) {
        do_send_token(&cap.token_bank_permission, bank, amount, recipient, ctx);
    }

    public entry fun send_staked_token(cap: &TokenCap, bank: &mut TokenBank, farm: &mut TokenFarm, amount: u64, delay_epoch: u64, unlock_epoch: u64, linear_unlock: bool, recipient: address, clock: &Clock, ctx: &mut TxContext) {
        do_send_staked_token(&cap.token_bank_permission, bank, farm, amount, delay_epoch, unlock_epoch, linear_unlock, recipient, clock, ctx);
    }

    public entry fun create_token_airdrop(cap: &TokenCap, bank: &mut TokenBank, public_key: vector<u8>, name: vector<u8>, amount: u64, free_amount: u64, allow_duplicate: bool, ctx: &mut TxContext) {
        do_create_token_airdrop(&cap.token_bank_permission, bank, public_key, name, amount, free_amount, allow_duplicate, ctx);
    }

    public entry fun set_token_bank_public_key(_: &TokenCap, bank: &mut TokenBank, public_key: vector<u8>) {
        df::remove_if_exists<u64, vector<u8>>(
            &mut bank.id,
            TokenBankPublicKey_Slot
        );
        df::add<u64, vector<u8>>(
            &mut bank.id,
            TokenBankPublicKey_Slot,
            public_key
        )
    }

    public entry fun create_token_ido(cap: &TokenCap, bank: &mut TokenBank, name: vector<u8>, price_e9: u64, is_public: bool, amount: u64, ctx: &mut TxContext) {
        do_create_token_ido(&cap.token_bank_permission, bank, name, price_e9, is_public, amount, ctx);
    }

    public entry fun change_token_ido_publicity(cap: &TokenCap, ido: &mut TokenIdo, is_public: bool, ctx: &mut TxContext) {
        do_change_token_ido_publicity(&cap.token_ido_permission, ido, is_public, ctx);
    }

    public entry fun change_token_ido_whitelists_editable(cap: &TokenCap, ido: &mut TokenIdo, editable: bool, _ctx: &mut TxContext) {
        do_change_token_ido_whitelists_editable(&cap.token_ido_permission, ido, editable, _ctx);
    }

    public entry fun create_token_farm(cap: &TokenCap, bank: &mut TokenBank, base_epochs: u64, min_stake_index: u64, stake_index_table_data: vector<u64>, ctx: &mut TxContext) {
        do_create_token_farm(&cap.token_bank_permission, bank, base_epochs, min_stake_index, stake_index_table_data, ctx);
    }

    public entry fun claim_token_airdrop_token(airdrop: &mut TokenAirdrop, amount: u64, signature: vector<u8>, ctx: &mut TxContext) {
        do_claim_token_airdrop_token(airdrop, amount, signature, ctx);
    }

    public entry fun add_token_ido_whitelist(cap: &TokenCap, ido: &mut TokenIdo, ctx: &mut TxContext) {
        do_add_token_ido_whitelist(&cap.token_ido_permission, ido, ctx);
    }

    public entry fun buy_token_ido_token(ido: &mut TokenIdo, in_suis: vector<Coin<SUI>>, in_amount: u64, ctx: &mut TxContext) {
        do_buy_token_ido_token(ido, in_suis, in_amount, ctx);
    }

    public entry fun stake_token(bank: &mut TokenBank, farm: &mut TokenFarm, c: Coin<TOKEN>, stake_time_index: u64, clock: &Clock, ctx: &mut TxContext) {
        do_stake_token(bank, farm, c, stake_time_index, clock, ctx);
    }

    public entry fun unlock_staked_token(farm: &mut TokenFarm, x: StakedToken, clock: &Clock, ctx: &mut TxContext) { 
        do_unlock_staked_token(farm, x, clock, ctx);
    }

    public entry fun unlock_linear_unlock_staked_token(x: LinearUnlockStakedToken, clock: &Clock, ctx: &mut TxContext) {
        do_unlock_linear_unlock_staked_token(x, clock, ctx);
    }

    public entry fun unwrap_linear_unlock_staked_token(farm: &mut TokenFarm, x: LinearUnlockStakedToken, clock: &Clock, ctx: &mut TxContext) {
        do_unwrap_linear_unlock_staked_token(farm, x, clock, ctx);
    }

    // #[test_only]
    // public entry fun early_unlock_staked_token(bank: &mut TokenBank, farm: &mut TokenFarm, x: StakedToken, clock: &Clock, ctx: &mut TxContext) {
    //     do_early_unlock_staked_token(bank, farm, x, clock, ctx);
    // }


    // ============================================= API =============================================

    // ============================================= Utils =============================================
    fun create_stake_token(farm: &mut TokenFarm, balance: Balance<TOKEN>, profit: Balance<TOKEN>, delay_epoch: u64, unlock_epoch: u64, boost_multiplier: u64, clock: &Clock, ctx: &mut TxContext): StakedToken {
        assert!(boost_multiplier > 0, ETokenInvalidParameter);

        let id_ = object::new(ctx);
        let current_epoch = utils::get_epoch(clock);
        let start_epoch = current_epoch + delay_epoch;
        let end_epoch = start_epoch + unlock_epoch;

        let amount = balance::value(&balance);
        let boost = (amount as u128) * (boost_multiplier as u128);
        farm.total_stake_amount = farm.total_stake_amount + amount;
        farm.total_stake_boost = farm.total_stake_boost + boost;

        StakedToken {
            id: id_,
            balance: sb::from_balance(balance),
            profit: sb::from_balance(profit),
            start_epoch: start_epoch,
            end_epoch: end_epoch,
            boost: boost
        }
    }

    fun destroy_stake_token(farm: &mut TokenFarm, st: StakedToken, clock: &Clock, _ctx: &mut TxContext): Balance<TOKEN> {
        let current_epoch = utils::get_epoch(clock);
        assert!(current_epoch >= st.end_epoch, ETokenCannotUnlockStakeTokenNotStarted);

        destroy_stake_token_force(farm, st)
    }

    fun destroy_stake_token_force(farm: &mut TokenFarm, st: StakedToken): Balance<TOKEN> {
        let dec_stake_amount = sb::value(&st.balance);
        let dec_stake_boost = st.boost;
        farm.total_stake_amount = farm.total_stake_amount - dec_stake_amount;
        farm.total_stake_boost = farm.total_stake_boost - dec_stake_boost;

        let StakedToken { id: id_, balance: balance, profit: profit, start_epoch: _, end_epoch: _, boost: _ } = st;
        object::delete(id_);

        let b1 = sb::into_balance(balance);
        let b2 = sb::into_balance(profit);
        balance::join(&mut b1, b2);

        b1
    }

    fun is_zero_stake_token(st: &StakedToken): bool {
        sb::value(&st.balance) == 0 && sb::value(&st.profit) == 0
    }

    fun destroy_zero_stake_token(st: StakedToken) {
        assert!(is_zero_stake_token(&st) == true, ETokenCannotDestoryHaveValueStakedToken);
        let StakedToken { id: id_, balance: balance, profit: profit, start_epoch: _, end_epoch: _, boost: _ } = st;
        object::delete(id_);
        sb::destroy_zero(balance);
        sb::destroy_zero(profit);
    }

    fun create_linear_unlock_stake_token(balance: Balance<TOKEN>, profit: Balance<TOKEN>, delay_epoch: u64, unlock_epoch: u64, boost_multiplier: u64, clock: &Clock, ctx: &mut TxContext): LinearUnlockStakedToken {
        let id_ = object::new(ctx);
        let current_epoch = utils::get_epoch(clock);
        let start_epoch = current_epoch + delay_epoch;
        let end_epoch = start_epoch + unlock_epoch;

        let boost = (balance::value(&balance) as u128) * (boost_multiplier as u128);

        let st = StakedToken {
            id: id_,
            balance: sb::from_balance(balance),
            profit: sb::from_balance(profit),
            start_epoch: start_epoch,
            end_epoch: end_epoch,
            boost: boost
        };

        let uid2_ = object::new(ctx);
        let id2_ = object::uid_to_inner(&uid2_);
        let linear_st = LinearUnlockStakedToken {
            id: uid2_,
            origin_id: id2_,
            inner: st
        };

        linear_st
    }

    fun transfer_or_destroy_zero_stake_token(st: StakedToken, recipient: address) {
        if (is_zero_stake_token(&st)) {
            destroy_zero_stake_token(st);
        }
        else {
            transfer::transfer(st, recipient);
        }
    }

    fun decrease_linear_unlock_stake_token(lst: &mut LinearUnlockStakedToken, clock: &Clock, _ctx: &mut TxContext): Balance<TOKEN> {
        let current_epoch = utils::get_epoch(clock);
        assert!(current_epoch >= lst.inner.start_epoch, ETokenCannotUnlockStakeTokenNotStarted);

        let st = &mut lst.inner;

        let left_ratio = if (st.end_epoch == st.start_epoch || current_epoch >= st.end_epoch) {
            ratio::ratio(0, 1)
        }
        else {
            let num = math::min(current_epoch, st.end_epoch) - st.start_epoch;
            let den = st.end_epoch - st.start_epoch;
            ratio::ratio(den - num, den)
        };

        let total_balance = sb::supply(&st.balance);
        let total_profit = sb::supply(&st.profit);

        // Get the unlock balance and unlock profit
        let should_left_balance = ratio::partial(left_ratio, total_balance);
        let should_left_profit = ratio::partial(left_ratio, total_profit);

        let current_left_balance = sb::value(&st.balance);
        let current_left_profit = sb::value(&st.profit);

        let b1_amount = if (should_left_balance <= current_left_balance) { current_left_balance - should_left_balance } else { 0 };
        let b2_amount = if (should_left_profit <= current_left_profit) { current_left_profit - should_left_profit } else { 0 };

        let b1 = sb::split(&mut st.balance, b1_amount);
        let b2 = sb::split(&mut st.profit, b2_amount);
        balance::join(&mut b1, b2);

        b1
    }

    fun unwrap_linear_unlock_stake_token(farm: &mut TokenFarm, lst: LinearUnlockStakedToken, clock: &Clock, ctx: &mut TxContext): StakedToken {
        let LinearUnlockStakedToken { id: id_, origin_id: _, inner: inner } = lst;
        object::delete(id_);

        let balance = sb::split_all(&mut inner.balance);
        let profit = sb::split_all(&mut inner.profit);

        let start_epoch = utils::get_epoch(clock);
        let end_epoch = inner.end_epoch;
        let unlock_epoch = if (end_epoch > start_epoch) { end_epoch - start_epoch } else { 0 };

        destroy_zero_stake_token(inner);
        let st = create_stake_token(farm, balance, profit, 0, unlock_epoch, TOKEN_STAKE_DEFAULT_BOOST_VALUE, clock, ctx);
        st
    }
    // ============================================= Utils =============================================

    // ============================================= Implementations =============================================
    fun init_impl(witness: TOKEN, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);

        // Create "Token" currency
        let (treasury_cap, coin_metadata) = coin::create_currency<TOKEN>(
            witness, // Withness
            9, // Decimals
            b"SSWP", // symbol
            b"Suiswap Token",
            b"Suiswap Platform Governance Token", // Description
            option::some(url::new_unsafe(ascii::string(b"https://suiswap.app/images/token/suiswap.svg"))),
            ctx // context
        );

        // Create a empty token bank
        let token_bank = TokenBank {
            id: object::new(ctx),
            version: VERSION,
            owner: sender,
            balance: sb::from_balance(balance::zero<TOKEN>()),
            admin_balance: balance::zero<TOKEN>(),
            early_unlock_fee: ratio::ratio(Config_EarlyUnlockTokenFeeNumerator, Config_EarlyUnlockTokenFeeDenominator),
            stats_liquidity_mine_amount: 0,
            token_farm_ids: vector::empty<ID>(),
            token_ido_ids: vector::empty<ID>(),
            token_airdrop_ids: vector::empty<ID>(),
        };

        let coin_metadata_id = object::id(&coin_metadata);
        let bank_id = object::id(&token_bank);

        transfer::public_freeze_object(coin_metadata);
        transfer::share_object(token_bank);

        let token_cap = TokenCap {
            id: object::new(ctx),
            treasury_cap: treasury_cap,
            token_bank_permission: permission::new<TokenBank>(),
            token_airdrop_permission: permission::new<TokenAirdrop>(),
            token_farm_permission: permission::new<TokenFarm>(),
            token_ido_permission: permission::new<TokenIdo>(),
            bank_id: bank_id,
            coin_metadata_id: coin_metadata_id,
        };
        transfer::transfer(token_cap, sender);
    }

    public fun do_increase_token_supply(cap: &mut TokenCap, bank: &mut TokenBank, amount: u64, ctx: &mut TxContext) {
        assert!(bank.version== VERSION, EVersionNotMatched);
        if (amount == 0) { return };

        let b = coin::into_balance(
            coin::mint<TOKEN>(&mut cap.treasury_cap, amount, ctx)
        );
        sb::increase(&mut bank.balance, b);

        assert!(sb::supply(&bank.balance) <= TOKEN_MAX_SUPPLY, ETokenOverMaxSupply);

        event::emit(IncreaseTokenSupplyEvent {
            bank_id: object::uid_to_inner(&bank.id),
            amount: amount
        });
    }

    public fun do_withdraw_token_bank_admin_balance(_: &Permission<TokenBank>, bank: &mut TokenBank, ctx: &mut TxContext) {
        assert!(bank.version== VERSION, EVersionNotMatched);
        let admin_balance_value = balance::value(&bank.admin_balance);
        let b = balance::split(&mut bank.admin_balance, admin_balance_value);

        event::emit(WithdarwTokenBankAdminBalance {
            amount: balance::value(&b)
        });

        utils::transfer_or_destroy_zero(
            coin::from_balance(b, ctx),
            tx_context::sender(ctx)
        );
    }

    public fun do_send_token(_: &Permission<TokenBank>, bank: &mut TokenBank, amount: u64, recipient: address, ctx: &mut TxContext) {
        assert!(bank.version== VERSION, EVersionNotMatched);
        if (amount == 0) { return };
        
        // Check the maximum balance
        let max_amount = sb::value(&bank.balance);
        assert!(amount <= max_amount, ETokenNotEnoughBalance);

        let b = sb::split(&mut bank.balance, amount);
        let c = coin::from_balance(b, ctx);
        let c_id = *object::borrow_id(&c);
        transfer::public_transfer(c, recipient);

        event::emit(SendTokenEvent { 
            token_id: c_id,
            bank_id: object::uid_to_inner(&bank.id),
            amount: amount,
            recipient: recipient,
            token_type: ESendTokenEvent_TokenType_Token
        });
    }

    public(friend) fun do_send_liquidity_mine_token(_: &Permission<TokenBank>, bank: &mut TokenBank, amount: u64, recipient: address, ctx: &mut TxContext) {
        assert!(bank.version== VERSION, EVersionNotMatched);
        do_send_token(_, bank, amount, recipient, ctx);
        bank.stats_liquidity_mine_amount = bank.stats_liquidity_mine_amount + amount;
    }

    public fun do_send_staked_token(_: &Permission<TokenBank>, bank: &mut TokenBank, farm: &mut TokenFarm, amount: u64, delay_epoch: u64, unlock_epoch: u64, linear_unlock: bool, recipient: address, clock: &Clock, ctx: &mut TxContext) {
        assert!(bank.version== VERSION && farm.version== VERSION, EVersionNotMatched);
        // if (amount == 0) { return };

        let max_amount = sb::value(&bank.balance);
        assert!(amount <= max_amount, ETokenNotEnoughBalance);

        // let sender = tx_context::sender(ctx);
        let bank_id = object::uid_to_inner(&bank.id);

        // Get the balance and profit
        let b = sb::split(&mut bank.balance, amount);
        let p = balance::zero<TOKEN>();

        if (linear_unlock == false) {
            let st = create_stake_token(farm, b, p, delay_epoch, unlock_epoch, TOKEN_STAKE_DEFAULT_BOOST_VALUE, clock, ctx);
            let st_id = object::uid_to_inner(&st.id);
            transfer::transfer(st, recipient);

            event::emit(SendTokenEvent { 
                token_id: st_id,
                bank_id: bank_id,
                amount: amount,
                recipient: recipient,
                token_type: ESendTokenEvent_TokenType_StakedToken
            });
        }
        else {
            let lst = create_linear_unlock_stake_token(b, p, delay_epoch, unlock_epoch, TOKEN_STAKE_DEFAULT_BOOST_VALUE, clock, ctx);
            let lst_id = object::uid_to_inner(&lst.id);
            transfer::transfer(lst, recipient);

            event::emit(SendTokenEvent {
                token_id: lst_id,
                bank_id: bank_id,
                amount: amount,
                recipient: recipient,
                token_type: ESendTokenEvent_TokenType_LineraUnlockStakedToken
            })
        };
    }

    public fun do_create_token_airdrop(_: &Permission<TokenBank>, bank: &mut TokenBank, public_key: vector<u8>, name: vector<u8>, amount: u64, free_amount: u64, allow_duplicate: bool, ctx: &mut TxContext) {
        assert!(bank.version== VERSION, EVersionNotMatched);
        assert!(amount > 0, ETokenInvalidParameter);
        assert!(free_amount <= amount, ETokenInvalidParameter);

        // Check the balance validation
        let max_amount = sb::value(&bank.balance);
        assert!(amount <= max_amount, ETokenNotEnoughBalance);

        let airdrop_uid = object::new(ctx);
        let airdrop_id = object::uid_to_inner(&airdrop_uid);
        vector::push_back(&mut bank.token_airdrop_ids, airdrop_id);

        // Create airdrop share object
        let airdrop = TokenAirdrop {
            id: airdrop_uid,
            version: VERSION,
            verify_id: airdrop_id,
            public_key: public_key,
            bank_id: object::uid_to_inner(&bank.id),
            owner: bank.owner,
            free_amount: free_amount,
            name: name,
            address_table: table::new<address, u8>(ctx),
            balance: sb::from_balance(sb::split(&mut bank.balance, amount)),
            allow_duplicate: allow_duplicate
        };
        transfer::share_object(airdrop);
    }

    public fun do_claim_token_airdrop_token_legacy(airdrop: &mut TokenAirdrop, amount: u64, signature: vector<u8>, ctx: &mut TxContext) { 
        assert!(airdrop.version== VERSION, EVersionNotMatched);

        // Check the amount
        assert!(amount <= sb::value(&airdrop.balance), ETokenNotEnoughBalance);

        // Get the sender and check whether we have airdropped
        let sender = tx_context::sender(ctx);
        
        if (airdrop.allow_duplicate == false) {
            assert!(token_airdrop_has_used_address(airdrop, sender) == false, ETokenAirdropHasAlreadyAirdropped);
        };

        // Get the sign verification
        let verified = if (token_airdrop_is_free(airdrop)) {
            (amount == airdrop.free_amount)
        } else {
            // Compose the message [name] + [verify_id] + [receiver] + [amount], signed by the airdrop owner
            let msg = airdrop.name; // Append the name
            vector::append(&mut msg, bcs::to_bytes(&airdrop.verify_id)); // Append the `airdrop_id`
            vector::append(&mut msg, bcs::to_bytes(&sender)); // Append the `receiver`
            vector::append(&mut msg, bcs::to_bytes(&amount)); // Append the `amount`

            // Debug
            // print(&string::utf8(b"nameBytes"));
            // print(&string::utf8(airdrop.name));
            // print(&string::utf8(b"airdropBytes"));
            // print(&string::utf8(hex::encode(bcs::to_bytes(&airdrop.verify_id))));
            // print(&string::utf8(b"userAddrBytes"));
            // print(&string::utf8(hex::encode(bcs::to_bytes(&sender))));
            // print(&string::utf8(b"amountBytes"));
            // print(&string::utf8(hex::encode(bcs::to_bytes(&amount))));
            // print(&string::utf8(b"Message"));
            // print(&string::utf8(hex::encode(copy msg)));

            // Check the validation of the message
            let verified = ed25519_verify(&signature, &airdrop.public_key, &msg);
            verified
        };
        assert!(verified, ETokenAirdropVerificationFailed);

        // Emit the event
        event::emit(ClaimTokenAirdropEvent {
            airdrop_id: object::uid_to_inner(&airdrop.id),
            amount: amount,
        });

        // Airdrop to the user
        let c = coin::from_balance(sb::split(&mut airdrop.balance, amount), ctx);
        transfer::public_transfer(c, sender);

        if (airdrop.allow_duplicate == false) {
            // Add the address so we could prove it has been airdropped
            table::add(&mut airdrop.address_table, sender, 1);
        };
    }

    public fun do_claim_token_airdrop_token(airdrop: &mut TokenAirdrop, amount: u64, signature: vector<u8>, ctx: &mut TxContext) {
        do_claim_token_airdrop_token_legacy(airdrop, amount, signature, ctx);
    }

    public fun do_create_token_ido(_: &Permission<TokenBank>, bank: &mut TokenBank, name: vector<u8>, price_e9: u64, is_public: bool, amount: u64, ctx: &mut TxContext) {
        assert!(bank.version== VERSION, EVersionNotMatched);

        assert!(price_e9 > 0, ETokenInvalidParameter);
        assert!(amount > 0, ETokenInvalidParameter);

        // Check the balance validation
        let max_amount = sb::value(&bank.balance);
        assert!(amount <= max_amount, ETokenNotEnoughBalance);

        let ido_uid = object::new(ctx);
        let ido_id = object::uid_to_inner(&ido_uid);
        vector::push_back(&mut bank.token_ido_ids, ido_id);

        // Create the ido and make it share
        let ido = TokenIdo {
            id: ido_uid,
            version: VERSION,
            bank_id: object::uid_to_inner(&bank.id),
            name: name,
            price_e9: price_e9,
            is_public: is_public,
            whitelists: table::new(ctx),
            is_whitelists_editable: true,
            collect: balance::zero<SUI>(),
            balance: sb::from_balance(sb::split(&mut bank.balance, amount)),
        };
        transfer::share_object(ido);
    }

    public fun add_token_ido_whitelist_impl(ido: &mut TokenIdo, ctx: &mut TxContext) {
        assert!(ido.version== VERSION, EVersionNotMatched);

        assert!(ido.is_whitelists_editable == true, ETokenIdoWhitelistMemberNotOpenToAdd);

        let sender = tx_context::sender(ctx);
        if (table::contains(&ido.whitelists, sender) == false) {
            table::add(&mut ido.whitelists, sender, 1);
        };

        event::emit(AddTokenIdoWhitelistEvent {
            ido_id: object::uid_to_inner(&ido.id)
        });
    }
    
    public fun do_add_token_ido_whitelist(_: &Permission<TokenIdo>, ido: &mut TokenIdo, ctx: &mut TxContext) {
        add_token_ido_whitelist_impl(ido, ctx);
    }

    public fun do_change_token_ido_publicity(_: &Permission<TokenIdo>, ido: &mut TokenIdo, is_public: bool, _ctx: &mut TxContext) {
        assert!(ido.version== VERSION, EVersionNotMatched);

        ido.is_public = is_public;
    }

    public fun do_change_token_ido_whitelists_editable(_: &Permission<TokenIdo>, ido: &mut TokenIdo, editable: bool, _ctx: &mut TxContext) {
        assert!(ido.version== VERSION, EVersionNotMatched);

        ido.is_whitelists_editable = editable;
    }

    public fun do_buy_token_ido_token(ido: &mut TokenIdo, in_suis: vector<Coin<SUI>>, in_amount: u64, ctx: &mut TxContext) {
        assert!(ido.version== VERSION, EVersionNotMatched);

        let sender = tx_context::sender(ctx);
        assert!(token_ido_is_public_or_has_whitelist_address(ido, sender) == true, ETokenIdoCannotBuyPermissionDenied);

        // Verify the out_amount
        let price_e9 = ido.price_e9;
        let out_amount = (((in_amount as u128) * (price_e9 as u128) / TOKEN_IDO_PRICE_SCALING) as u64);

        // Check the amount, shrink the amount and transfer back if needed
        let max_amount = sb::value(&ido.balance);
        if (out_amount > max_amount) {
            // Should be:
            // max_amount <= (new_in_amount * price_e9) // 1e9
            // new_in_amount <= ceil[(max_amount * 1e9) / price_e9]
            // new_in_amount = ((max_amount * 1e9) + (price_e9 - 1)) // price_e9
            out_amount = max_amount;
            in_amount = {
                let ma = (max_amount as u128);
                let ps = (TOKEN_IDO_PRICE_SCALING as u128);
                let pr = (price_e9 as u128);
                let result = (ma * ps + (pr - 1)) / pr;
                (result as u64)
            };

            // Uncomment to check
            // assert!(
            //     (((in_amount as u128) * (price_e9 as u128) / TOKEN_IDO_PRICE_SCALING) as u64) >= out_amount,
            //     0
            // );
            // assert!(
            //     ((((in_amount - 1) as u128) * (price_e9 as u128) / TOKEN_IDO_PRICE_SCALING) as u64) < out_amount,
            //     0
            // );

        };

        // Get the in balance and out balance
        let in_balance = coin::into_balance(
            utils::merge_coins_to_amount_and_transfer_back_rest(in_suis, in_amount, ctx)
        );

        let out_balance = sb::split(&mut ido.balance, out_amount);
        let out_coin = coin::from_balance(out_balance, ctx);

        // Transfer
        balance::join(&mut ido.collect, in_balance);
        transfer::public_transfer(out_coin, tx_context::sender(ctx));

        // Emit event
        event::emit(BuyTokenIdoTokenEvent {
            ido_id: object::uid_to_inner(&ido.id),
            in_amount: in_amount,
            out_amount: out_amount
        });
    }
    
    /// Create a token yield farm
    public fun do_create_token_farm(_: &Permission<TokenBank>, bank: &mut TokenBank, base_epochs: u64, min_stake_index: u64, stake_index_table_data: vector<u64>, ctx: &mut TxContext) {
        assert!(bank.version== VERSION, EVersionNotMatched);
        assert!(base_epochs > 0 && vector::length(&stake_index_table_data) % 3 == 0, ETokenInvalidParameter);

        // The `stake_index_table_data` should be a vector like [1, profit_1, boost_multiplier_1, 2, profit_2, boost_multiplier_2, ...]. Indicating the profit of each index.
        let token_farm_uid = object::new(ctx);
        let token_farm_id = object::uid_to_inner(&token_farm_uid);
        vector::push_back(&mut bank.token_farm_ids, token_farm_id);

        let bank_id = object::uid_to_inner(&bank.id);
        let stake_index_table = table::new<u64, TokenFarmIndexValue>(ctx);
        
        while (vector::length(&stake_index_table_data) > 0) {
            let boost_multiplier = vector::pop_back(&mut stake_index_table_data);
            let profit = vector::pop_back(&mut stake_index_table_data);
            let index = vector::pop_back(&mut stake_index_table_data);
            table::add(&mut stake_index_table, index, TokenFarmIndexValue { profit: profit, boost_multiplier: boost_multiplier });
        };

        let token_farm = TokenFarm {
            id: token_farm_uid,
            version: VERSION,
            bank_id: bank_id,
            base_epochs: base_epochs,
            min_stake_index: min_stake_index,
            stake_index_table: stake_index_table,
            total_stake_amount: 0,
            total_stake_boost: 0
        };

        transfer::share_object(token_farm);
    }

    public fun do_stake_token(bank: &mut TokenBank, farm: &mut TokenFarm, c: Coin<TOKEN>, stake_time_index: u64, clock: &Clock, ctx: &mut TxContext) {
        assert!(bank.version== VERSION && farm.version == VERSION, EVersionNotMatched);

        assert!(stake_time_index >= farm.min_stake_index, ETokenStakeIndexLessThanTheMinStakeIndex);
        assert!(coin::value(&c) > 0, ETokenInvalidParameter);
        assert!(table::contains(&farm.stake_index_table, stake_time_index), ETokenInvalidStakeIndex);

        let sender = tx_context::sender(ctx);
        let info = table::borrow(&farm.stake_index_table, stake_time_index);

        // Get the balance from the coin
        let balance_value = coin::value(&c);
        let balance = coin::into_balance(c);

        // Get the profit
        let profit_value = ratio::partial(ratio::ratio(info.profit, TOKEN_STAKE_PROFIT_SCALING), balance_value);
        // assert!(profit_value <= sb::value(&bank.balance), ETokenCannotStakeNotEnoughBankBalance);
        let profit = if (profit_value <= sb::value(&bank.balance)) { 
            sb::split(&mut bank.balance, profit_value) 
        } else { 
            balance::zero<TOKEN>() 
        };

        // Create the staked token
        let boost_multiplier = info.boost_multiplier;
        let unlock_epoch = stake_time_index * farm.base_epochs;
        let st = create_stake_token(farm, balance, profit, 0, unlock_epoch, boost_multiplier, clock, ctx);
        event::emit(StakeTokenEvent {
            st_id: object::uid_to_inner(&st.id),
        });
        transfer::transfer(st, sender);
    }

    public fun do_unlock_staked_token(farm: &mut TokenFarm, x: StakedToken, clock: &Clock, ctx: &mut TxContext) { 
        assert!(farm.version== VERSION, EVersionNotMatched);

        let sender = tx_context::sender(ctx);

        event::emit(UnlockStakeTokenEvent {
            st_id: object::uid_to_inner(&x.id)
        });

        let balance = destroy_stake_token(farm, x, clock, ctx);
        utils::transfer_or_destroy_zero(
            coin::from_balance(balance, ctx),
            sender
        );
    }

    public fun do_unlock_linear_unlock_staked_token(x: LinearUnlockStakedToken, clock: &Clock, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);

        // Send back the coin
        let c = coin::from_balance(
            decrease_linear_unlock_stake_token(&mut x, clock, ctx),
            ctx
        );
        utils::transfer_or_destroy_zero(c, sender);

        // Copy the staked token and transfer back 
        let LinearUnlockStakedToken { id: id_, origin_id: origin_id, inner: st } = x;
        object::delete(id_);

        if (is_zero_stake_token(&st)) {
            destroy_zero_stake_token(st);
        }
        else {
            let new_lst = LinearUnlockStakedToken { 
                id: object::new(ctx), 
                origin_id: origin_id, 
                inner: st 
            };
            transfer::transfer(new_lst, sender);
        };
    }

    public fun do_unwrap_linear_unlock_staked_token(farm: &mut TokenFarm, x: LinearUnlockStakedToken, clock: &Clock, ctx: &mut TxContext) {

        assert!(farm.version== VERSION, EVersionNotMatched);

        let st = unwrap_linear_unlock_stake_token(farm, x, clock, ctx);
        event::emit(UnwrapLinearUnlockStakedTokenEvent {
            st_id: object::uid_to_inner(&st.id)
        });
        transfer_or_destroy_zero_stake_token(st, tx_context::sender(ctx));
    }

    // #[test_only]
    // public fun do_early_unlock_staked_token(bank: &mut TokenBank, farm: &mut TokenFarm, x: StakedToken, clock: &Clock, ctx: &mut TxContext) {
    //     assert!(farm.version== VERSION && bank.version == VERSION, EVersionNotMatched);

    //     let current_epoch = utils::get_epoch(clock);
    //     assert!(current_epoch >= x.start_epoch, ETokenEarlyUnlockStakeTokenNotStarted);
    //     assert!(current_epoch < x.end_epoch, ETokenEarlyUnlockStakeTokenEpochError);

    //     // It's okay to split the profit to the admin account without considering the farm because the farm
    //     // only counts the "balance" field not the "profit" field in the supply
    //     balance::join(&mut bank.admin_balance, sb::split_all(&mut x.profit));

    //     // Destory the stake token
    //     let b = destroy_stake_token_force(farm, x);
    //     let b_value = balance::value(&b);

    //     // Join the withdraw fee 
    //     let fee_value = ratio::partial(bank.early_unlock_fee, b_value);
    //     let fee = balance::split(&mut b, fee_value);
    //     balance::join(&mut bank.admin_balance, fee);

    //     // Transfer the rest to the user
    //     let sender = tx_context::sender(ctx);
    //     let c = coin::from_balance(b, ctx);
    //     utils::transfer_or_destroy_zero(c, sender);
    // }
    // ============================================= Implementations =============================================
} 