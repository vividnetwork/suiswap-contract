// Copyright (c) 2022, Vivid Network Contributors
// SPDX-License-Identifier: Apache-2.0

module suiswap::pool {
    use std::vector;
    use std::option::{ Self, Option };
    use sui::object::{Self, UID, ID};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::transfer;
    use sui::math;
    use sui::event;
    use sui::package;
    use sui::bcs;
    use sui::ed25519::{ ed25519_verify };
    use sui::clock::Clock;
    use sui::tx_context::{Self, TxContext};
    use sui::dynamic_field::{ Self as df };
    use suiswap::utils::{ Self };
    use suiswap::ratio::{ Self };
    use suiswap::permission::{ Permission };
    use suiswap::TOKEN::{ Self as token, StakedToken, TokenFarm, TokenCap, TokenBank };
    use suiswap::vpt::{ Self, ValuePerToken };

    const VERSION: u64 = 0;

    // const NUMBER_1E8: u128 = 100000000;

    // const ERouteSwapDirectionForward: u8 = 0;
    // const ERouteSwapDirectionReverse: u8 = 1;

    const INITIAL_LSP_MINIMUM_SHARE: u64 = 1000;

    const EPoolTypeV2: u8 = 100;
    const EPoolTypeStableSwap: u8 = 101;

    const EFeeDirectionX: u8 = 200;
    const EFeeDirectionY: u8 = 201;

    const EPoolFreezeSwapBit: u8 = 1;
    const EPoolFreezeAddLiquidityBit: u8 = 2;
    const EPoolFreezeRemoveLiquidityBit: u8 = 4;

    const ETokenHolderRewardTypeBalance: u8 = 210;
    const ETokenHolderRewardTypeAutoBackBuy: u8 = 211;

    /// For when supplied Coin is zero.
    const EInvalidParameter: u64 = 13400;
    /// For when pool fee is set incorrectly.  Allowed values are: [0-10000)
    const EWrongFee: u64 = 134001;
    /// For when someone tries to swap in an empty pool.
    const EReservesEmpty: u64 = 134002;
    /// For when initial LSP amount is zero.02
    // const EShareEmpty: u64 = 134003;
    /// For when someone attemps to add more liquidity than u128 Math allows.3
    // const EPoolFull: u64 = 134004;
    /// For when the internal operation overflow.
    const EOperationOverflow: u64 = 134005;
    /// For when some intrinsic computation error detects
    const EComputationError: u64 = 134006;
    /// Can not operate this operation
    const EPermissionDenied: u64 = 134007;
    /// Not enough balance for operation
    const ENotEnoughBalance: u64 = 134008;
    /// Not coin registed
    // const ECoinNotRegister: u64 = 134009;
    /// Pool freezes for operation 
    const EPoolFreeze: u64 = 134010;
    /// Slippage limit error
    const ESlippageLimit: u64 = 134011;
    /// Pool not found
    // const EPoolNotFound: u64 = 134012;
    /// Create duplicate pool
    const EPoolDuplicate: u64 = 134013;
    /// Stable coin decimal too large
    const ECreatePoolStableCoinDecimalTooLarge: u64 = 134014;
    /// No implementeed error code
    // const ENoImplement: u64 = 134015;
    /// Deprecated
    // const EDeprecated: u64 = 134016;
    /// Cannot get the token reward current stake epoch is too late
    const EPoolClaimTokenHolderRewardErrorStakeEpochError: u64 = 134017;
    /// Try to add liquidity with specified locked epoch but it cannot be found in the smart contract
    const EPoolAddLiquidityLockedLspEpochNotFound: u64 = 134018;
    /// Cannot remove the liquidity, current epoch is smaller than the unlock epoch
    const EPoolCannotRemoveLiquidityUnlockEpochNotReached: u64 = 134019;
    /// Cannot merge two pool lsp together, field not match
    const EPoolLspCannotMergeFieldNotMatch: u64 = 134020;
    /// Already create pool registry, we cannot recreate one
    const EPoolRegistryAlreadyCreated: u64 = 134021;
    /// Cannot claim token reward from non balance token reward pool
    const EPoolClaimTokenHolderRewardWrongPoolType: u64 = 134022;
    /// Too small lsp for initial pool creation
    const ETooSmallLspAmountForInitialPoolLiquidity: u64 = 134023;

    /// Not correct version
    const EVersionNotMatched: u64 = 200000;

    /// The integer scaling setting for fees calculation.
    // const BPS_SCALING_U128: u128 = 10000;
    const BPS_SCALING_U64: u64 = 10000;
    /// The maximum number of u64
    const U64_MAX: u128 = 18446744073709551615u128;
    const U64_MAX_U64: u64 = 18446744073709551615u64;
    const U64_MAX_U256: u256 = 18446744073709551615;

    /// The max decimal of stable swap coin
    const STABLESWAP_COIN_MAX_DECIMAL: u8 = 18;
    const STABLESWAP_N_COINS: u64 = 2;
    const STABLESWAP_MIN_AMP: u64 = 1;
    const STABLESWAP_MAX_AMP: u64 = 1000000;

    /// The interval between the snapshot in seconds
    const SNAPSHOT_INTERVAL_SEC: u64 = 900;
    /// The interval between the refreshing the total trade 24h
    // const TOTAL_TRADE_24H_INTERVAL_SEC: u64 = 86400;
    /// The interval between captuing the bank amount
    // const BANK_AMOUNT_SNAPSHOT_INTERVAL_SEC: u64 = 3600 * 6;
    /// The default 
    const POOL_LSP_DEFAULT_BOOST_MULTIPLIER: u64 = 10;

    struct POOL has drop {}

    /// Emit when pool is created
    struct PoolCreateEvent has copy, drop, store {
        pool_id: ID
    }

    struct SwapTokenEvent<phantom X, phantom Y> has copy, drop {
        // The index of the pool
        pool_index: u64,
        // When the direction is x to y or y to x
        x_to_y: bool,
        // The in token amount
        in_amount: u64,
        // The out token amount
        out_amount: u64,
    }

    struct LiquidityEvent<phantom X, phantom Y> has copy, drop {
        // The index of the pool
        pool_index: u64,
        // Whether it is a added/removed liqulity event or remove liquidity event
        is_added: bool,
        // The x amount to added/removed
        x_amount: u64,
        // The y amount to added/removed
        y_amount: u64,
        // The lsp amount to added/removed
        lsp_amount: u64,
        // The id of the lsp
        lsp_id: ID,
    }

    struct SnapshotEvent<phantom X, phantom Y> has copy, drop, store {
        // The index of the pool
        pool_index: u64,
        x: u64,
        y: u64,
        lsp: u64
    }

    /// The capability of the Suiswap, used for inidicating 
    /// admin-level operation
    struct SwapCap has key {
        id: UID,
        /// The registry id
        registry_id: Option<ID>
    }

    /// The pool create info that should be stored to the creator
    /// Store as dynamic fields in pool registries, representing a Pool<X, Y> has been created
    struct PoolCreateInfo has copy, drop, store {
        /// The ID of the pool
        pool_id: ID,
        /// An additional field to check whether the type is reverse or not (when store by PoolCreateInfoKey)
        reverse: bool,
    }

    public fun pool_create_info_get_pool_id(v: &PoolCreateInfo): ID { v.pool_id }

    /// This creation info is generated by reverse side creation. Thus, when we create a Pool<X, Y>. 
    /// It generates two PoolCreateInfo, one is PoolCreateInfo<X, Y> and another is 
    /// PoolCreateInfo<Y, X> with same pool_id...
    struct PoolCreateInfoKey<phantom X, phantom Y> has copy, drop, store {}

    /// The Pool token that will be used to mark the pool share
    /// of a liquidity provider. The first type parameter stands
    /// for the witness type of a pool. The seconds is for the
    /// coin held in the pool.
    struct LSP<phantom X, phantom Y> has drop {}

    struct PoolNoAdminSetupInfo has store {
        /// Whether allow the creation of the pool for non-admin user
        allowance: bool,
        /// The fee direction for non-admin pool
        fee_direction: u8,
        /// The admin fee for non-admin user
        admin_fee: u64,
        /// The lp fee for non-admin user
        lp_fee: u64,
        /// The token holder fee for non-admin user
        th_fee: u64,
        /// The default withdraw fee for non-admin user
        withdraw_fee: u64,
    }

    struct PoolBoostMultiplierData has store, copy, drop {
        epoch: u64,
        boost_multiplier: u64
    }

    /// All the pools shoule be registered in here. 
    /// It uses the dynamic fields to link to all the PoolCreateInfo
    struct PoolRegistry has key { 
        /// The ID of the pool registry
        id: UID,
        /// The version of the pool registry
        version: u64,
        /// The counter couting how many pools have been created
        pool_counter: u64,
        /// The no-admin pool creation info
        pool_no_admin: PoolNoAdminSetupInfo,
        /// The token holder reward epoch
        pool_th_reward_nepoch: u64,
        /// The boost multiplier data, used for locked lsp liquidity addings
        pool_boost_multiplier_data: vector<PoolBoostMultiplierData>
    }

    public fun pool_registry_get_id(v: & PoolRegistry): ID { object::uid_to_inner(&v.id) }
    public fun pool_registry_get_pool_counter(v: & PoolRegistry): u64 { v.pool_counter }

    public fun pool_registry_get_no_admin_pool_allowance(v: &PoolRegistry): bool { v.pool_no_admin.allowance }
    public fun pool_registry_get_no_admin_pool_fee_direction(v: &PoolRegistry): u8 { v.pool_no_admin.fee_direction }
    public fun pool_registry_get_no_admin_pool_admin_fee(v: &PoolRegistry): u64 { v.pool_no_admin.admin_fee }
    public fun pool_registry_get_no_admin_pool_lp_fee(v: &PoolRegistry): u64 { v.pool_no_admin.lp_fee }
    public fun pool_registry_get_no_admin_pool_th_fee(v: &PoolRegistry): u64 { v.pool_no_admin.th_fee}
    public fun pool_registry_get_no_admin_pool_withdraw_fee(v: &PoolRegistry): u64 { v.pool_no_admin.withdraw_fee }

    public fun pool_registry_set_no_admin_pool_allowance(_: &SwapCap, v: &mut PoolRegistry, x: bool) { v.pool_no_admin.allowance = x; }
    public fun pool_registry_set_no_admin_pool_fee_direction(_: &SwapCap, v: &mut PoolRegistry, x: u8) { v.pool_no_admin.fee_direction = x; }
    public fun pool_registry_set_no_admin_pool_admin_fee(_: &SwapCap, v: &mut PoolRegistry, x: u64) { v.pool_no_admin.admin_fee = x; }
    public fun pool_registry_set_no_admin_pool_lp_fee(_: &SwapCap, v: &mut PoolRegistry, x: u64) { v.pool_no_admin.lp_fee = x; }
    public fun pool_registry_set_no_admin_pool_th_fee(_: &SwapCap, v: &mut PoolRegistry, x: u64) { v.pool_no_admin.th_fee = x;}
    public fun pool_registry_set_no_admin_pool_withdraw_fee(_: &SwapCap, v: &mut PoolRegistry, x: u64) { v.pool_no_admin.withdraw_fee = x; }

    struct PoolTotalTradeInfo has store {
        /// Number of x has been traded
        x: u128,
        /// Number of y has been traded
        y: u128,

        /// Number of x has been traded (last epoch)
        x_last_epoch: u128,
        /// Number of y has been traded (last epoch)
        y_last_epoch: u128,
        
        /// Number of x has been traded (current epoch)
        x_current_epoch: u128,
        /// Number of y has been traded (current epoch)
        y_current_epoch: u128,
    }

    struct PoolTokenHolderRewardInfo<phantom X, phantom Y> has store {
        /// The token holder rewards type
        ///    - Balance: Part of the trading fee will transfer into balance and could be redeemed by token holder
        ///    - AutoBuyBack: Part of the trading fee will be used to automatically buy back token
        type: u8,
        /// The balance of X for token holder to claim
        x: Balance<X>,
        /// The balance of Y for token holder to claim
        y: Balance<Y>,
        /// The origin supply balance of X for token holder to claim
        x_supply: u64,
        /// The origin supply balance of Y for token holder to claim
        y_supply: u64,
        /// The epoch for single reward reward round
        nepoch: u64,
        /// The current reward start epoch (include)
        start_epcoh: u64,
        /// The current reward end epoch (include)
        end_epoch: u64,
        /// The total amount of staked token when taking the snapshot 
        total_stake_amount: u64,
        /// The total boost of staked token when taking the snapshot
        total_stake_boost: u128,
    }

    struct PoolLiquidityMiningInfo has store {
        /// The TokenBank permission, need this permission to send token to the rewarder when unlock
        permission: Option<Permission<TokenBank>>,
        /// The mining speed of token, number of token will be mined per epoch (total in the pool)
        speed: u256,
        /// The current amvpt(accumulated mined token per token)
        ampt: ValuePerToken,
        /// The last epoch for mining
        last_epoch: u64,
    }

    struct PoolFeeInfo has store {
        /// Affects how the admin fee and connect fee are extracted.
        /// For a pool with quote coin X and base coin Y. 
        /// - When `fee_direction` is EFeeDirectionX, we always
        /// collect quote coin X for admin_fee & conY. 
        /// - When `fee_direction` is EFeeDirectionY, we always 
        /// collect base coin Y for admin_fee & connect_fee.
        direction: u8,
        /// Admin fee is denominated in basis points, in bps
        admin: u64,
        /// Liqudity fee is denominated in basis points, in bps
        lp: u64,
        /// Token holder fee is denominated in basis points, in bps
        th: u64,
        /// The withdraw fee for the pool
        withdraw: u64,
    }

    struct PoolBalanceInfo<phantom X, phantom Y> has store {
        /// The balance of X token in the pool
        x: Balance<X>,
        /// The balance of token in the pool
        y: Balance<Y>,
        /// The balance of X that admin collects
        x_admin: Balance<X>,
        /// The balance of token that admin collects
        y_admin: Balance<Y>,
        /// The balance of X the token holders collect
        x_th: Balance<X>,
        /// The balance of Y the token holders collect
        y_th: Balance<Y>,
        /// The basis for x
        bx: u64,
        /// The basis for y
        by: u64,
    }

    struct PoolStableInfo has store { 
        /// Stable pool amplifier
        amp: u64, 
        /// The scaling factor that aligns x's decimal to 18
        x_scale: u64,
        /// The scaling factor that aligns y's decimal to 18
        y_scale: u64,
    }

    /// Pool struct for Suiswap.
    /// Note: Split Pool struct into sub-struture to avoid the move analyser validation of max struct size (30)
    struct Pool<phantom X, phantom Y> has key {
        id: UID,

        /// The version of the pool
        version: u64,

        /// Owner
        owner: address, 

        /// The index of the pool
        index: u64,

        /// The pool type
        pool_type: u8,

        /// The current lsp supply value as u64
        lsp_supply: u64,

        /// Whether the pool is freezed for swapping and adding liquidity
        freeze: u8,

        /// The last trade epoch
        trade_epoch: u64,

        /// The boost multiplier data for creating the lock token
        boost_multiplier_data: vector<PoolBoostMultiplierData>,

        /// The fee strsture info
        fee: PoolFeeInfo,

        /// The stable struct info
        stable: PoolStableInfo, 

        /// The balance struct info
        balance: PoolBalanceInfo<X, Y>,

        /// The total trade info
        total_trade: PoolTotalTradeInfo,

        /// the token holder reward info
        th_reward: PoolTokenHolderRewardInfo<X, Y>,

        /// The liquidity mining info
        mining: PoolLiquidityMiningInfo,
    }

    public fun pool_get_id<X, Y>(v: &Pool<X, Y>): ID { object::uid_to_inner(&v.id) }
    public fun pool_get_index<X, Y>(v: &Pool<X, Y>): u64 { v.index }
    public fun pool_get_owner<X, Y>(v: &Pool<X, Y>): address { v.owner }
    public fun pool_get_pool_type<X, Y>(v: &Pool<X, Y>): u8 { v.pool_type }
    public fun pool_get_lsp_supply<X, Y>(v: &Pool<X, Y>): u64 { v.lsp_supply }
    public fun pool_get_freeze<X, Y>(v: &Pool<X, Y>): u8 { v.freeze }
    public fun pool_get_trade_epoch<X, Y>(v: &Pool<X, Y>): u64 { v.trade_epoch }
    public fun pool_get_boost_multiplier_length<X, Y>(v: &Pool<X, Y>): u64 { vector::length(&v.boost_multiplier_data) }
    public fun pool_get_boost_multiplier_data<X, Y>(v: &Pool<X, Y>, index: u64): PoolBoostMultiplierData { *vector::borrow(&v.boost_multiplier_data, index) }

    public fun pool_get_fee_direction<X, Y>(v: &Pool<X, Y>): u8 { v.fee.direction }
    public fun pool_get_fee_admin<X, Y>(v: &Pool<X, Y>): u64 { v.fee.admin }
    public fun pool_get_fee_lp<X, Y>(v: &Pool<X, Y>): u64 { v.fee.lp }
    public fun pool_get_fee_th<X, Y>(v: &Pool<X, Y>): u64 { v.fee.th }
    public fun pool_get_fee_withdraw<X, Y>(v: &Pool<X, Y>): u64 { v.fee.withdraw }

    public fun pool_get_stable_amp<X, Y>(v: &Pool<X, Y>): u64 { v.stable.amp }
    public fun pool_get_stable_x_scale<X, Y>(v: &Pool<X, Y>): u64 { v.stable.x_scale }
    public fun pool_get_stable_y_scale<X, Y>(v: &Pool<X, Y>): u64 { v.stable.y_scale }

    public fun pool_get_balance_x_value<X, Y>(v: &Pool<X, Y>): u64 { balance::value(&v.balance.x) }
    public fun pool_get_balance_y_value<X, Y>(v: &Pool<X, Y>): u64 { balance::value(&v.balance.y) }
    public fun pool_get_balance_x_admin_value<X, Y>(v: &Pool<X, Y>): u64 { balance::value(&v.balance.x_admin) }
    public fun pool_get_balance_y_admin_value<X, Y>(v: &Pool<X, Y>): u64 { balance::value(&v.balance.y_admin) }
    public fun pool_get_balance_x_th_value<X, Y>(v: &Pool<X, Y>): u64 { balance::value(&v.balance.x_th) }
    public fun pool_get_balance_y_th_value<X, Y>(v: &Pool<X, Y>): u64 { balance::value(&v.balance.y_th) }

    public fun pool_get_total_trade_x<X, Y>(v: &Pool<X, Y>): u128 { v.total_trade.x }
    public fun pool_get_total_trade_y<X, Y>(v: &Pool<X, Y>): u128 { v.total_trade.y }
    public fun pool_get_total_trade_x_last_epoch<X, Y>(v: &Pool<X, Y>): u128 { v.total_trade.x_last_epoch }
    public fun pool_get_total_trade_y_last_epoch<X, Y>(v: &Pool<X, Y>): u128 { v.total_trade.y_last_epoch }
    public fun pool_get_total_trade_x_current_epoch<X, Y>(v: &Pool<X, Y>): u128 { v.total_trade.x_current_epoch }
    public fun pool_get_total_trade_y_current_epoch<X, Y>(v: &Pool<X, Y>): u128 { v.total_trade.y_current_epoch }

    public fun pool_get_th_reward_type<X, Y>(v: &Pool<X, Y>): u8 { v.th_reward.type }
    public fun pool_get_th_reward_x_value<X, Y>(v: &Pool<X, Y>): u64 { balance::value(&v.th_reward.x) }
    public fun pool_get_th_reward_y_value<X, Y>(v: &Pool<X, Y>): u64 { balance::value(&v.th_reward.y) }
    public fun pool_get_th_reward_x_supply<X, Y>(v: &Pool<X, Y>): u64 { v.th_reward.x_supply }
    public fun pool_get_th_reward_y_supply<X, Y>(v: &Pool<X, Y>): u64 { v.th_reward.y_supply }
    public fun pool_get_th_reward_nepoch<X, Y>(v: &Pool<X, Y>): u64 { v.th_reward.nepoch }
    public fun pool_get_th_reward_start_epcoh<X, Y>(v: &Pool<X, Y>): u64 { v.th_reward.start_epcoh }
    public fun pool_get_th_reward_end_epoch<X, Y>(v: &Pool<X, Y>): u64 { v.th_reward.end_epoch }
    public fun pool_get_th_reward_total_stake_amount<X, Y>(v: &Pool<X, Y>): u64 { v.th_reward.total_stake_amount }
    public fun pool_get_th_reward_total_stake_boost<X, Y>(v: &Pool<X, Y>): u128 { v.th_reward.total_stake_boost }

    public fun pool_get_mining_has_permission<X, Y>(v: &Pool<X, Y>): bool { option::is_some(&v.mining.permission) }
    public fun pool_get_mining_speed<X, Y>(v: &Pool<X, Y>): u256 { v.mining.speed }
    public fun pool_get_mining_ampt<X, Y>(v: &Pool<X, Y>): ValuePerToken { v.mining.ampt }
    public fun pool_get_mining_last_epoch<X, Y>(v: &Pool<X, Y>): u64 { v.mining.last_epoch }

    struct PoolLsp<phantom X, phantom Y> has key {
        id: UID,
        /// The ID of the pool
        pool_id: ID,
        /// The value of the lsp
        value: u64,
        /// The x balance in the pool when created
        pool_x: u64,
        /// The y balance in the pool when created
        pool_y: u64,
        /// The lsp amount in the pool when created
        pool_lsp: u64,
        /// The pool mining_amvpt when created the lsp
        pool_mining_ampt: ValuePerToken,
        /// The start epoch for the lsp token
        start_epoch: u64,
        /// The end epoch for the lsp token
        end_epoch: u64,
        /// The boost value for for the lsp token
        boost_multiplier: u64,
    }

    public fun pool_lsp_get_id<X, Y>(v: &PoolLsp<X, Y>): ID { object::uid_to_inner(&v.id) }
    public fun pool_lsp_get_pool_id<X, Y>(v: &PoolLsp<X, Y>): ID { v.pool_id }
    public fun pool_lsp_get_value<X, Y>(v: &PoolLsp<X, Y>): u64 { v.value }
    public fun pool_lsp_get_pool_x<X, Y>(v: &PoolLsp<X, Y>): u64 { v.pool_x }
    public fun pool_lsp_get_pool_y<X, Y>(v: &PoolLsp<X, Y>): u64 { v.pool_y }

    /// Module initializer is empty - to publish a new Pool one has
    /// to create a type which will mark LSPs.
    fun init(otw: POOL, ctx: &mut TxContext) {
        package::claim_and_keep(otw, ctx);
        init_impl(ctx);
    }

    // ============================================= API =============================================

    /// Create the pool registry. 
    /// The `boost_multipler_data` should be in the form [epoch_1, boost_1, epoch_2, boost_2, epoch_3, boost_3, ....].
    public entry fun create_registry(cap: &mut SwapCap, th_rewrad_epoch: u64, boost_multiplier_data: vector<u64>, ctx: &mut TxContext) {
        do_create_registry(cap, th_rewrad_epoch, boost_multiplier_data, ctx)
    }

    public entry fun create_pool<X, Y>(
        _: &SwapCap,
        reg: &mut PoolRegistry, 
        farm: &TokenFarm,
        pool_type: u8,
        pool_th_reward_type: u8,
        fee_direction: u8,
        admin_fee: u64,
        lp_fee: u64,
        th_fee: u64,
        withdraw_fee: u64,
        stable_amp: u64,
        stable_x_decimal: u8,
        stable_y_decimal: u8,
        bx: u64,
        by: u64,
        freeze_bit: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        do_create_pool<X, Y>(
            _, reg, farm, pool_type,  pool_th_reward_type,  fee_direction,  admin_fee,  lp_fee,  th_fee,  withdraw_fee, stable_amp,  stable_x_decimal,  stable_y_decimal, bx, by, freeze_bit, clock, ctx,
        );
    }

    public entry fun change_fee<X, Y>(cap: &SwapCap, pool: &mut Pool<X, Y>, new_admin_fee: u64, new_lp_fee: u64, new_th_fee: u64, ctx: &mut TxContext) {
        do_change_fee(cap, pool, new_admin_fee, new_lp_fee, new_th_fee, ctx);
    }

    public entry fun freeze_pool<X, Y>(cap: & SwapCap, pool: &mut Pool<X, Y>) {
        do_set_pool_freeze(cap, pool, EPoolFreezeSwapBit | EPoolFreezeAddLiquidityBit | EPoolFreezeRemoveLiquidityBit);
    }

    public entry fun unfreeze_pool<X, Y>(cap: & SwapCap, pool: &mut Pool<X, Y>) {
        do_set_pool_freeze(cap, pool, 0);
    }

    public entry fun redeem_admin_balance<X, Y>(_: & SwapCap, pool: &mut Pool<X, Y>, x_amount: u64, y_amount: u64, ctx: &mut TxContext) {
        do_redeem_admin_balance(_, pool, x_amount, y_amount, ctx);
    }

    public entry fun change_pool_mining_speed<X, Y>(_: &SwapCap, token_cap: &TokenCap, pool: &mut Pool<X, Y>, speed: u64) {
        do_change_pool_mining_speed(_, token_cap, pool, speed);
    }

    public entry fun create_pool_no_admin<X, Y>(reg: &mut PoolRegistry, farm: &TokenFarm, clock: &Clock, ctx: &mut TxContext) {
        do_create_pool_no_admin<X, Y>(reg, farm, clock, ctx);
    }

    public entry fun swap_x_to_y<X, Y>(pool: &mut Pool<X, Y>, x: vector<Coin<X>>, in_amount: u64, min_out_amount: u64, clock: &Clock, ctx: &mut TxContext) {
        do_swap_x_to_y(pool, x, in_amount, min_out_amount, clock, ctx);
    }

    public entry fun swap_y_to_x<X, Y>(pool: &mut Pool<X, Y>, y: vector<Coin<Y>>, in_amount: u64, min_out_amount: u64, clock: &Clock, ctx: &mut TxContext) {
        do_swap_y_to_x(pool, y, in_amount, min_out_amount, clock, ctx);
    }

    public entry fun swap_x_to_y_all<X, Y>(pool: &mut Pool<X, Y>, x: vector<Coin<X>>, min_out_amount: u64, clock: &Clock, ctx: &mut TxContext) {
        let x = utils::merge_coins(x, ctx);
        let x_amount = coin::value(&x);
        do_swap_x_to_y(pool, vector::singleton(x), x_amount, min_out_amount, clock, ctx);
    }

    public entry fun swap_y_to_x_all<X, Y>(pool: &mut Pool<X, Y>, y: vector<Coin<Y>>, min_out_amount: u64, clock: &Clock, ctx: &mut TxContext) {
        let y = utils::merge_coins(y, ctx);
        let y_amount = coin::value(&y);
        do_swap_y_to_x(pool, vector::singleton(y), y_amount, min_out_amount, clock, ctx);
    }

    public entry fun add_liquidity<X, Y>(pool: &mut Pool<X, Y>, x: vector<Coin<X>>, y: vector<Coin<Y>>, in_x_amount: u64, in_y_amount: u64, unlock_epoch: u64, clock: &Clock, ctx: &mut TxContext) {
        do_add_liquidity(pool, x, y, in_x_amount, in_y_amount, unlock_epoch, clock, ctx);
    }

    public entry fun remove_liquidity<X, Y>(pool: &mut Pool<X, Y>, bank: &mut TokenBank, lsp: PoolLsp<X, Y>, lsp_amount: u64, clock: &Clock, ctx: &mut TxContext) {
        do_remove_liquidity(pool, bank, lsp, lsp_amount, clock, ctx);
    }

    public entry fun add_liquidity_all<X, Y>(pool: &mut Pool<X, Y>, x: vector<Coin<X>>, y: vector<Coin<Y>>, unlock_epoch: u64, clock: &Clock, ctx: &mut TxContext) {
        let x = utils::merge_coins(x, ctx);
        let y = utils::merge_coins(y, ctx);
        let in_x_amount = coin::value(&x);
        let in_y_amount = coin::value(&y);
        do_add_liquidity(pool, vector::singleton(x), vector::singleton(y), in_x_amount, in_y_amount, unlock_epoch, clock, ctx);
    }

    public entry fun remove_liquidity_all<X, Y>(pool: &mut Pool<X, Y>, bank: &mut TokenBank, lsp: PoolLsp<X, Y>, clock: &Clock, ctx: &mut TxContext) {
        let amount = lsp.value;
        do_remove_liquidity(pool, bank, lsp, amount, clock, ctx);
    }

    public entry fun claim_th_reward<X, Y>(farm: &TokenFarm, st: &mut StakedToken, pool: &mut Pool<X, Y>, clock: &Clock, ctx: &mut TxContext) {
        do_claim_th_reward(farm, st, pool, clock, ctx);
    }

    public entry fun update_th_reward<X, Y>(farm: &TokenFarm, pool: &mut Pool<X, Y>, clock: &Clock, ctx: &mut TxContext) {
        do_update_th_reward(farm, pool, clock, ctx);
    }
    // ============================================= API =============================================

    // ============================================= Getter =============================================
    /// Get most used values in a handy way:
    /// - amount of SUI
    /// - amount of token
    /// - total supply of LSP
    public fun get_amounts<X, Y>(pool: &Pool<X, Y>): (u64, u64, u64) {
        (
            balance::value(&pool.balance.x) + pool.balance.bx,
            balance::value(&pool.balance.y) + pool.balance.by,
            pool.lsp_supply,
        )
    }

    /// Get The admin X and Y token balance value
    public fun get_admin_amounts<X, Y>(pool: &Pool<X, Y>): (u64, u64) {
        (
            balance::value(&pool.balance.x_admin),
            balance::value(&pool.balance.y_admin)
        )
    }

    /// Get the "k" value (d^2) for the pool
    public fun get_k<X, Y>(pool: &Pool<X, Y>): u256 {
        let (x, y, _) = get_amounts(pool);

        if (pool.pool_type == EPoolTypeV2) {
            (x as u256) * (y as u256)
        } else {
            let d = ss_compute_d((x as u256), (y as u256), (pool.stable.amp as u256));
            d * d
        }
    }

    public fun get_k2_per_lsp<X, Y>(pool: &Pool<X, Y>): u256 {
        let (x, y, l) = get_amounts(pool);
        let x = (x as u256);
        let y = (y as u256);
        let l = (l as u256);
        if (l == 0) {
            0
        } else {
            (x * y) / (l * l)
        }
    }
    // ============================================= Getter =============================================

    // ============================================= Utilities =============================================
    fun create_pool_impl<X, Y>(
        reg: &mut PoolRegistry, 
        farm: &TokenFarm,
        pool_type: u8,
        pool_th_reward_type: u8,
        fee_direction: u8,
        admin_fee: u64,
        lp_fee: u64,
        th_fee: u64,
        withdraw_fee: u64,
        stable_amp: u64,
        stable_x_decimal: u8,
        stable_y_decimal: u8,
        bx: u64,
        by: u64,
        freeze_bit: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(fee_direction == EFeeDirectionX || fee_direction == EFeeDirectionY, EInvalidParameter);
        assert!(pool_type == EPoolTypeV2 || pool_type == EPoolTypeStableSwap, EInvalidParameter);
        assert!(pool_th_reward_type == ETokenHolderRewardTypeBalance || pool_th_reward_type == ETokenHolderRewardTypeAutoBackBuy, EInvalidParameter);
        
        assert!(lp_fee + admin_fee + th_fee < BPS_SCALING_U64, EWrongFee);

        // Check existance
        let exists_xy = df::exists_<PoolCreateInfoKey<X, Y>>(&mut reg.id, PoolCreateInfoKey<X, Y>{});
        let exists_yx = df::exists_<PoolCreateInfoKey<Y, X>>(&mut reg.id, PoolCreateInfoKey<Y, X>{});
        assert!(!exists_xy && !exists_yx, EPoolDuplicate);

        let pool_uid = object::new(ctx);
        let pool_id = object::uid_to_inner(&pool_uid);

        // Get the pool index
        let pool_index = reg.pool_counter;
        reg.pool_counter = reg.pool_counter + 1;

        // Compute the stable_x_scale and stable_y_scale
        let stable_x_scale: u64 = 0;
        let stable_y_scale: u64 = 0;
        if (pool_type == EPoolTypeStableSwap) {
            let x_decimal = stable_x_decimal;
            let y_decimal = stable_y_decimal;

            assert!(x_decimal <= STABLESWAP_COIN_MAX_DECIMAL && y_decimal <= STABLESWAP_COIN_MAX_DECIMAL, ECreatePoolStableCoinDecimalTooLarge);
            assert!(stable_amp >= STABLESWAP_MIN_AMP && stable_amp <= STABLESWAP_MAX_AMP, EInvalidParameter);

            // To align the decimal into one
            if (x_decimal < y_decimal) {
                stable_x_scale = math::pow(10, y_decimal - x_decimal);
                stable_y_scale = 1;
            } else {
                // x_decimal > y_decimal
                stable_x_scale = 1;
                stable_y_scale = math::pow(10, x_decimal - y_decimal);
            };
        };

        // Create pool and pool creation info
        let current_epoch = utils::get_epoch(clock);
        let th_reward_nepoch = reg.pool_th_reward_nepoch;

        // Get current reward epoch
        let (th_reward_start_epcoh, th_reward_end_epoch) = get_th_reward_start_and_end_epoch(current_epoch, th_reward_nepoch);
        let sender = tx_context::sender(ctx);
        let pool = Pool<X, Y> {
            id: pool_uid,
            version: VERSION,
            owner: sender,
            index: pool_index,
            pool_type: pool_type,
            lsp_supply: 0u64,
            freeze: freeze_bit,
            trade_epoch: current_epoch,
            boost_multiplier_data: reg.pool_boost_multiplier_data,
            fee: PoolFeeInfo {
                direction: fee_direction,
                admin: admin_fee,
                lp: lp_fee,
                th: th_fee,
                withdraw: withdraw_fee,
            },
            stable: PoolStableInfo {
                amp: stable_amp,
                x_scale: stable_x_scale,
                y_scale: stable_y_scale,
            },
            balance: PoolBalanceInfo<X, Y> {
                x: balance::zero<X>(),
                y: balance::zero<Y>(),
                x_admin: balance::zero<X>(),
                y_admin: balance::zero<Y>(),
                x_th: balance::zero<X>(),
                y_th: balance::zero<Y>(),
                bx: bx,
                by: by,
            },
            total_trade: PoolTotalTradeInfo {
                x: 0u128,
                y: 0u128,
                x_last_epoch: 0u128,
                y_last_epoch: 0u128,
                x_current_epoch: 0u128,
                y_current_epoch: 0u128,
            },
            th_reward: PoolTokenHolderRewardInfo<X, Y> {
                type: pool_th_reward_type,
                x: balance::zero<X>(),
                y: balance::zero<Y>(),
                x_supply: 0,
                y_supply: 0,
                nepoch: th_reward_nepoch,
                start_epcoh: th_reward_start_epcoh,
                end_epoch: th_reward_end_epoch,
                total_stake_amount: token::token_farm_get_total_stake_amount(farm),
                total_stake_boost: token::token_farm_get_total_stake_boost(farm),
            },
            mining: PoolLiquidityMiningInfo {
                permission: option::none<Permission<TokenBank>>(),
                speed: 0,
                ampt: vpt::zero(),
                last_epoch: current_epoch + 1 // Not this epoch
            }
        };

        // Update the token holder reward 
        do_update_th_reward(farm, &mut pool, clock, ctx);

        // Add to the dynamic pool of pool registry
        df::add(&mut reg.id, PoolCreateInfoKey<X, Y> { }, PoolCreateInfo { pool_id: pool_id, reverse: false });
        df::add(&mut reg.id, PoolCreateInfoKey<Y, X> { }, PoolCreateInfo { pool_id: pool_id, reverse: true });

        // Make the pool share
        transfer::share_object(pool);

        // Emit the pool create event
        event::emit(PoolCreateEvent { pool_id: pool_id });
    }
    
    fun collect_fee<X>(balance: &mut Balance<X>, fee: u64): Balance<X> {
        utils::split_partial_balance(balance, ratio::ratio(fee, BPS_SCALING_U64))
    }

    fun collect_admin_and_th_fee_x<X, Y>(pool: &mut Pool<X, Y>, balance: &mut Balance<X>) {
        if (pool.fee.direction == EFeeDirectionX) {
            let admin_fee = pool.fee.admin;
            let th_fee = pool.fee.th;

            balance::join(
                &mut pool.balance.x_admin,
                collect_fee(balance, admin_fee)
            );

            balance::join(
                &mut pool.balance.x_th,
                collect_fee(balance, th_fee)
            );
        };
    }

    fun collect_admin_and_th_fee_y<X, Y>(pool: &mut Pool<X, Y>, balance: &mut Balance<Y>) {
        if (pool.fee.direction == EFeeDirectionY) {
            let admin_fee = pool.fee.admin;
            let th_fee = pool.fee.th;

            balance::join(
                &mut pool.balance.y_admin,
                collect_fee(balance, admin_fee)
            );

            balance::join(
                &mut pool.balance.y_th,
                collect_fee(balance, th_fee)
            );
        }
    }

    fun process_auto_buyback<X, Y>(pool: &mut Pool<X, Y>) {
        // Try to use the balance "x_th" and "y_th" in the pool (due to the )
        if (pool.th_reward.type == ETokenHolderRewardTypeAutoBackBuy) {
            if (pool.fee.direction == EFeeDirectionX && balance::value(&pool.balance.x_th) > 0) {
                let pool_x_th_value = balance::value(&pool.balance.x_th);
                let ix = balance::split(&mut pool.balance.x_th, pool_x_th_value);
                let oy = swap_x_to_y_direct_no_fee_impl(pool, ix);
                balance::join(&mut pool.balance.y_th, oy);
            }
            else if (pool.fee.direction == EFeeDirectionY && balance::value(&pool.balance.y_th) > 0) {
                let pool_y_th_value = balance::value(&pool.balance.y_th);
                let iy = balance::split(&mut pool.balance.y_th, pool_y_th_value);
                let ox = swap_y_to_x_direct_no_fee_impl(pool, iy);
                balance::join(&mut pool.balance.x_th, ox);
            }
        };   
    }

    fun collect_withdraw_fee<X, Y>(pool: &mut Pool<X, Y>, bx: &mut Balance<X>, by: &mut Balance<Y>) {
        let withdraw_fee = pool.fee.withdraw;
        balance::join(
            &mut pool.balance.x_admin,
            collect_fee(bx, withdraw_fee)
        );
        balance::join(
            &mut pool.balance.y_admin,
            collect_fee(by, withdraw_fee)
        );
    }

    fun update_th_reward_impl<X, Y>(farm: &TokenFarm, pool: &mut Pool<X, Y>, current_epoch: u64) {
        assert!(pool.version== VERSION, EVersionNotMatched);

        if (current_epoch > pool.th_reward.end_epoch) {
            let (new_start_epoch, new_end_epoch) = get_th_reward_start_and_end_epoch(current_epoch, pool.th_reward.nepoch);
            pool.th_reward.start_epcoh = new_start_epoch;
            pool.th_reward.end_epoch = new_end_epoch;

            // Join the rest balance into the admin balance
            utils::join_balance(&mut pool.balance.x_admin, &mut pool.th_reward.x);
            utils::join_balance(&mut pool.balance.y_admin, &mut pool.th_reward.y);

            // Join the current round th reward into
            utils::join_balance(&mut pool.th_reward.x, &mut pool.balance.x_th);
            utils::join_balance(&mut pool.th_reward.y, &mut pool.balance.y_th);
            pool.th_reward.x_supply = balance::value(&pool.th_reward.x);
            pool.th_reward.y_supply = balance::value(&pool.th_reward.y);

            // Get the total staked token and total staked boot amount
            pool.th_reward.total_stake_amount = token::token_farm_get_total_stake_amount(farm);
            pool.th_reward.total_stake_boost = token::token_farm_get_total_stake_boost(farm);
        }
    }

    fun claim_th_reward_impl<X, Y>(farm: &TokenFarm, st: &mut StakedToken, pool: &mut Pool<X, Y>, clock: &Clock, ctx: &mut TxContext): u64 {
        assert!(pool.version == VERSION, EVersionNotMatched);
        assert!(pool.th_reward.type == ETokenHolderRewardTypeBalance, EPoolClaimTokenHolderRewardWrongPoolType);

        // Update the token reward if needed
        let current_epoch = utils::get_epoch(clock);
        update_th_reward_impl(farm, pool, current_epoch);

        // Check whether user use the same stake token to reclaim the reward for the same pool
        let start_epcoh = token::staked_token_get_start_epoch(st);
        let last_stake_epcoh_opt = token::staked_token_pop_data(st, pool.index);
        let last_stake_epcoh = option::get_with_default(&last_stake_epcoh_opt, start_epcoh);

        if (last_stake_epcoh >= pool.th_reward.start_epcoh) {
            return EPoolClaimTokenHolderRewardErrorStakeEpochError
        };

        // So that it must be counted in the snapshot
        let num = token::staked_token_get_boost(st);
        let den = pool.th_reward.total_stake_boost;
        if (den == 0) { 
            num = 0;
            den = 1;
        };

        let th_reward_x_value = num * (pool.th_reward.x_supply as u128) / den;
        let th_reward_y_value = num * (pool.th_reward.y_supply as u128) / den;
        let th_reward_x_value = (th_reward_x_value as u64);
        let th_reward_y_value = (th_reward_y_value as u64);

        // Generate the balance
        let bx = balance::split(&mut pool.th_reward.x, th_reward_x_value);
        let by = balance::split(&mut pool.th_reward.y, th_reward_y_value);

        // Merge to coin
        let cx = coin::from_balance(bx, ctx);
        let cy = coin::from_balance(by, ctx);

        // Transfer back to the sender
        let sender = tx_context::sender(ctx);
        utils::transfer_or_destroy_zero(cx, sender);
        utils::transfer_or_destroy_zero(cy, sender);

        // Add the data to avoid reclaim
        token::staked_token_add_data<u64, u64>(st, pool.index, current_epoch);

        return 0
    }

    fun add_liquidity_direct_impl<X, Y>(pool: &mut Pool<X, Y>, x: vector<Coin<X>>, y: vector<Coin<Y>>, in_x_amount: u64, in_y_amount: u64, unlock_epoch: u64, allow_price_move: bool, clock: &Clock, ctx: &mut TxContext): PoolLsp<X, Y> {
        assert!(pool.version== VERSION, EVersionNotMatched);
        if (tx_context::sender(ctx) != pool.owner) {
            assert!((pool.freeze & EPoolFreezeAddLiquidityBit) == 0, EPoolFreeze);
        };

        let bx = coin::into_balance(utils::merge_coins(x, ctx));
        let by = coin::into_balance(utils::merge_coins(y, ctx));
        assert!(balance::value(&bx) >= in_x_amount, ENotEnoughBalance);
        assert!(balance::value(&by) >= in_y_amount, ENotEnoughBalance);

        // Update the liquidity mining global data to avoid the error for update latency 
        // ( so that user could use the latency update data to get profit)
        update_pool_mining(pool, clock);

        let start_epoch = utils::get_epoch(clock);
        let end_epoch = start_epoch + unlock_epoch;
        let boost_multiplier = POOL_LSP_DEFAULT_BOOST_MULTIPLIER;
        if (end_epoch > start_epoch) {
            // Try to find with the unlock_epoch
            let i = 0; let n = vector::length(&pool.boost_multiplier_data);
            while (i < n) {
                let v = vector::borrow(&pool.boost_multiplier_data, i);
                if (v.epoch == unlock_epoch) {
                    boost_multiplier = v.boost_multiplier;
                    break
                };
                i = i + 1;
            };
            // Iterate but cannot found the epoch
            assert!(i < n, EPoolAddLiquidityLockedLspEpochNotFound);
        };

        let x_added = in_x_amount;
        let y_added = in_y_amount;

        let sender = tx_context::sender(ctx);

        let (x_amt, y_amt, lsp_supply) = get_amounts(pool);

        let x_added_desired: u64 = x_added;
        let y_added_desired: u64 = y_added;
        let share_minted_locked: u64 = 0;
        let share_minted = if (lsp_supply > 0) {
            // When it is not a intialized the deposit, we compute the amount of minted lsp by
            // not reducing the "token / lsp" value.
            let shared_minted = if (pool.pool_type == EPoolTypeV2) {
                if (allow_price_move) {
                    compute_deposit_allow_price_move(x_added, y_added, x_amt, y_amt, lsp_supply)
                } else {
                    let mint_x = compute_deposit(x_added, x_amt, lsp_supply);
                    let mint_y = compute_deposit(y_added, y_amt, lsp_supply);
                    let mint = if (mint_x > mint_y) { mint_y } else { mint_x };
                    x_added_desired = compute_deposit_reverse(mint, lsp_supply, x_amt);
                    y_added_desired = compute_deposit_reverse(mint, lsp_supply, y_amt);
                    assert!(x_added_desired <= x_added && y_added_desired <= y_added, EComputationError);
                    mint
                }
            } else {
                compute_deposit_stable(x_added, y_added, x_amt, y_amt, lsp_supply, pool.stable.x_scale, pool.stable.y_scale, pool.stable.amp)
            };

            shared_minted
        } else {
            // When it is a initialzed deposit, we compute using sqrt(x_added) * sqrt(y_added)
            share_minted_locked = INITIAL_LSP_MINIMUM_SHARE;
            let share_minted: u64 = math::sqrt(x_amt + x_added) * math::sqrt(y_amt + y_added);
            share_minted
        };
        assert!(share_minted > INITIAL_LSP_MINIMUM_SHARE, ETooSmallLspAmountForInitialPoolLiquidity);
        assert!(share_minted > 0, EComputationError);

        let x_balance = balance::split(&mut bx, x_added_desired);
        let y_balance = balance::split(&mut by, y_added_desired);

        let _ = balance::join(&mut pool.balance.x, x_balance);
        let _ = balance::join(&mut pool.balance.y, y_balance);

        // Mint lsp coin and transfer, the locked should be zero for adding liquidity
        let lsp_coin = increase_lsp_supply(pool, share_minted - share_minted_locked, start_epoch, end_epoch, boost_multiplier, ctx);
        // Add the locking lsp info, updating the pool info but not minting any lsp, so that it seems like those lsp is locked
        increase_pool_lsp_info(pool, share_minted_locked, boost_multiplier);

        // Transfer back to the sender 
        utils::transfer_or_destroy_zero(
            coin::from_balance(bx, ctx),
            sender
        );
        utils::transfer_or_destroy_zero(
            coin::from_balance(by, ctx),
            sender
        );

        event::emit(LiquidityEvent<X, Y> {
            pool_index: pool.index,
            is_added: true,
            x_amount: x_added,
            y_amount: y_added,
            lsp_amount: share_minted,
            lsp_id: object::uid_to_inner(&lsp_coin.id)
        });

        lsp_coin
    }

    fun remove_liquidity_impl<X, Y>(pool: &mut Pool<X, Y>, bank: &mut TokenBank, lsp: PoolLsp<X, Y>, lsp_amount: u64, remove_type: u8, force: bool, clock: &Clock, ctx: &mut TxContext) {
        assert!(remove_type <= 2, EInvalidParameter);
        assert!(pool.version== VERSION, EVersionNotMatched);
        if (tx_context::sender(ctx) != pool.owner) {
            assert!((pool.freeze & EPoolFreezeRemoveLiquidityBit) == 0, EPoolFreeze);
        };

        assert!(lsp_amount > 0, EInvalidParameter);
        assert!(lsp.value >= lsp_amount, ENotEnoughBalance);

        if (force == false) {
            let current_epoch = utils::get_epoch(clock);
            assert!(current_epoch >= lsp.end_epoch, EPoolCannotRemoveLiquidityUnlockEpochNotReached);
        };

        update_pool_mining(pool, clock);

        let sender = tx_context::sender(ctx);
        let lsp_id = object::uid_to_inner(&lsp.id);

        // If there's a non-empty LSP, we can

        // We should make the value "token / lsp" larger than the previous value before removing liqudity
        // Thus 
        // (token - dtoken) / (lsp - dlsp) >= token / lsp
        //  ==> (token - dtoken) * lsp >= token * (lsp - dlsp)
        //  ==> -dtoken * lsp >= -token * dlsp
        //  ==> dtoken * lsp <= token * dlsp
        //  ==> dtoken <= token * dlsp / lsp
        //  ==> dtoken = floor[token * dlsp / lsp] <= token * dlsp / lsp
        // We use the floor operation
        let (x_amt, y_amt, lsp_supply) = get_amounts(pool);
        let (x_removed, y_removed) = if (pool.pool_type == EPoolTypeV2) {
            compute_withdraw(x_amt, y_amt, lsp_supply, lsp_amount, remove_type)
        } else {
            compute_withdraw_stable(x_amt, y_amt, lsp_supply, lsp_amount, pool.stable.x_scale, pool.stable.y_scale, pool.stable.amp)
        };

        // Claim the token use the diff value of new minus old
        let lsp_boost = (lsp.value as u256) * (lsp.boost_multiplier as u256);
        let lsp_mining_token_amount = vpt::diff(&pool.mining.ampt, &lsp.pool_mining_ampt, lsp_boost);
        assert!(lsp_mining_token_amount <= U64_MAX_U256, EComputationError);
        let lsp_mining_token_amount = (lsp_mining_token_amount as u64);

        // Withdraw the token from the bank
        if (token::token_bank_get_balance_value(bank) >= lsp_mining_token_amount && option::is_some(&pool.mining.permission) && lsp_mining_token_amount > 0) {
            let pr = option::borrow(&pool.mining.permission);
            token::do_send_liquidity_mine_token(pr, bank, lsp_mining_token_amount, sender, ctx);
        };

        // Transfer back or destroy lsp coin
        let lsp_after_take = remove_lsp_supply(pool, lsp, lsp_amount, ctx);

        if (lsp_after_take.value > 0) { 
            transfer::transfer(lsp_after_take, sender); 
        } else {
            destroy_zero_lsp(lsp_after_take);
        };
        
        let (balance_x_removed, balance_y_removed) = (
            balance::split(&mut pool.balance.x, x_removed),
            balance::split(&mut pool.balance.y, y_removed)
        );

        collect_withdraw_fee(pool, &mut balance_x_removed, &mut balance_y_removed);

        let (coin_x_removed, coin_y_removed) = (
            coin::from_balance(balance_x_removed, ctx),
            coin::from_balance(balance_y_removed, ctx)
        );

        utils::transfer_or_destroy_zero(coin_x_removed, sender);
        utils::transfer_or_destroy_zero(coin_y_removed, sender);

        if (remove_type == 2) {
            // TODO: Remove later
            // Check:
            // x_amt / lsp_supply <= x_amt_after / lsp_supply_after
            //    ==> x_amt * lsp_supply_after <= x_amt_after * lsp_supply
            let (x_amt_after, y_amt_after, lsp_supply_after) = get_amounts(pool); {
                let x_amt_ = (x_amt as u128);
                let y_amt_ = (y_amt as u128);
                let lsp_supply_ = (lsp_supply as u128);
                let x_amt_after_ = (x_amt_after as u128);
                let y_amt_after_ = (y_amt_after as u128);
                let lsp_supply_after_ = (lsp_supply_after as u128);
                assert!(x_amt_ * lsp_supply_after_ <= x_amt_after_ * lsp_supply_, EComputationError);
                assert!(y_amt_ * lsp_supply_after_ <= y_amt_after_ * lsp_supply_, EComputationError);
            };
        };

        event::emit(LiquidityEvent<X, Y> {
            pool_index: pool.index,
            is_added: false,
            x_amount: x_removed,
            y_amount: y_removed,
            lsp_amount: lsp_amount,
            lsp_id: lsp_id
        });
    }

    /// Given dx (dx > 0), x and y. Ensure the constant product 
    /// market making (CPMM) equation fulfills after swapping:
    /// (x + dx) * (y - dy) = x * y
    /// Due to the integter operation, we change the equality into
    /// inequadity operation, i.e:
    /// (x + dx) * (y - dy) >= x * y
    fun compute_amount(dx: u64, x: u64, y: u64): u64 {
        // (x + dx) * (y - dy) >= x * y
        //    ==> y - dy >= (x * y) / (x + dx)
        //    ==> dy <= y - (x * y) / (x + dx)
        //    ==> dy <= (y * dx) / (x + dx)
        //    ==> dy = floor[(y * dx) / (x + dx)] <= (y * dx) / (x + dx)
       let (dx, x, y) = ((dx as u128), (x as u128), (y as u128));
        
        let numerator: u128 = y * dx;
        let denominator: u128 = x + dx;
        let dy: u128 = numerator / denominator;
        assert!(dy <= U64_MAX, EOperationOverflow);

        // Addition liqudity check, should not happen
        let k_after: u128 = (x + dx) * (y - dy);
        let k_before: u128 = x * y;
        assert!(k_after >= k_before, EComputationError);

        (dy as u64)
    }

    fun compute_amount_stable(dx: u64, x: u64, y: u64, x_scale: u64, y_scale: u64, amp: u64): u64 {
        let x_scale = (x_scale as u256);
        let y_scale = (y_scale as u256);

        // Decimal align
        let dx = (dx as u256) * x_scale;
        let x = (x as u256) * x_scale;
        let y = (y as u256) * y_scale;

        let amp = (amp as u256);

        let dy = ss_swap_to(dx, x, y, amp); 
        
        // Revert to the original decimal, since we hope to small less, so use floor rounding instead of ceil rounding 
        let dy = dy / y_scale;
        let dy = (dy as u64);

        dy
    }


    fun compute_deposit(x_added: u64, x: u64, supply: u64): u64 {
        // When it is not a intialized the deposit, we compute the amount of minted lsp by
        // not reducing the "token / lsp" value.

        // We should make the value "token / lsp" larger than the previous value before adding liqudity
        // Thus 
        // (token + dtoken) / (lsp + dlsp) >= token / lsp
        //  ==> (token + dtoken) * lsp >= token * (lsp + dlsp)
        //  ==> dtoken * lsdp >= token * dlsp
        //  ==> dlsp <= dtoken * lsdp / token
        //  ==> dslp = floor[dtoken * lsdp / token] <= dtoken * lsdp / token
        // We use the floor operation
        let mint: u128 = ((x_added as u128) * (supply as u128)) / (x as u128);
        (mint as u64)
    }

    fun compute_deposit_reverse(mint: u64, supply: u64, x: u64): u64 {
        // dlsp = floor[dx * lsp / x]
        // ==> dlsp <= dx * lsp / x < dlsp + 1
        // ==> dlsp * x <= dx * lsp < (dlsp + 1) * x
        // ==> dlsp * x / lsp <= dx < (dlsp + 1) * x / lsp
        // ==> dx = ceil[dlsp * x / lsp]

        let mint: u128 = (mint as u128);
        let supply: u128 = (supply as u128);
        let x: u128 = (x as u128);

        let x_added = (mint * x + (supply - 1)) / supply;
        (x_added as u64)
    }

    fun compute_deposit_allow_price_move(x_added: u64, y_added: u64, x: u64, y: u64, supply: u64): u64 {
        // Make sure the 
        //     (x * y) / l^2 <= (x' * y') / l'^2
        // ==> l' <= x' * y' * l^2 / (x * y )
        let x1 = ((x + x_added) as u256);
        let y1 = ((y + y_added) as u256);
        let x0 = (x as u256);
        let y0 = (y as u256);
        let l0 = (supply as u256);

        let l1_2 = (x1 * y1 * l0 * l0) / (x0 * y0);
        let l1 = (math::sqrt_u128((l1_2 as u128)) as u64);
        l1 - supply
    }

    fun compute_deposit_stable(x_added: u64, y_added: u64, x: u64, y: u64, supply: u64, x_scale: u64, y_scale: u64, amp: u64): u64 {
        let x_scale = (x_scale as u256);
        let y_scale = (y_scale as u256);

        // Align decimal
        let x = (x as u256) * x_scale;
        let y = (y as u256) * y_scale;
        let x_added = (x_added as u256) * x_scale;
        let y_added = (y_added as u256) * y_scale;

        let supply = (supply as u256);
        let amp = (amp as u256);

        let shared_minted = ss_compute_mint_amount_for_deposit(x_added, y_added, x, y, supply, amp);
        let shared_minted = (shared_minted as u64);
        shared_minted
    }

    fun compute_withdraw(x: u64, y: u64, supply: u64, amount: u64, remove_type: u8): (u64, u64) {
        if (remove_type == 2) {
            // We should make the value "token / lsp" larger than the previous value before removing liqudity
            // Thus 
            // (token - dtoken) / (lsp - dlsp) >= token / lsp
            //  ==> (token - dtoken) * lsp >= token * (lsp - dlsp)
            //  ==> -dtoken * lsp >= -token * dlsp
            //  ==> dtoken * lsp <= token * dlsp
            //  ==> dtoken <= token * dlsp / lsp
            //  ==> dtoken = floor[token * dlsp / lsp] <= token * dlsp / lsp
            // We use the floor operation

            let x_removed = ((x as u128) * (amount as u128)) / (supply as u128);
            let y_removed = ((y as u128) * (amount as u128)) / (supply as u128);
            let x_removed = (x_removed as u64);
            let y_removed = (y_removed as u64);
            return (x_removed, y_removed)
        };

        // For x, we have:
        //     x' y / lsp'^2 >= x y / lsp^2
        // ==> x' >= x * lsp'^2 / (lsp^2)
        // ==> dx <= x -  (x lsp'^2) / (lsp^2)
        // 
        // Same for y, we have:
        // ==> dy <= y - (y lsp'^2 / lsp^2)
        let lsp_: u256 = ((supply - amount) as u256);
        let lsp: u256 = (supply as u256);

        let lsp2_ = lsp_ * lsp_;
        let lsp2 = lsp * lsp;

        if (remove_type == 0) {
            let x_ = (((x as u256) * lsp2_ / lsp2) as u64);
            return (x - x_, 0)
        }
        else {
            let y_ = (((y as u256) * lsp2_ / lsp2) as u64);
            return (0, y - y_)
        }
    }

    fun compute_withdraw_stable(x: u64, y: u64, supply: u64, amount: u64, x_scale: u64, y_scale: u64, amp: u64): (u64, u64) {
        let x_scale = (x_scale as u256);
        let y_scale = (y_scale as u256);

        let supply = (supply as u256);
        let amount = (amount as u256);
        let amp = (amp as u256);

        let x = ((x as u256) * x_scale);
        let y = ((y as u256) * y_scale);

        let (x_removed, y_removed) = ss_compute_withdraw(amount, supply, x, y, amp);
        
        // Use floor rounding for we want to remove less
        let x_removed = ((x_removed / x_scale) as u64);
        let y_removed = ((y_removed / y_scale) as u64);
        (x_removed, y_removed)
    }

    fun swap_x_to_y_direct_no_fee_impl<X, Y>(pool: &mut Pool<X, Y>, in_balance: Balance<X>): Balance<Y> {
        // Get the output amount
        let (px, py, _) = get_amounts(pool);
        assert!(px > 0 && py > 0, EReservesEmpty);
        
        let out_amount = if (pool.pool_type == EPoolTypeV2) {
            compute_amount(balance::value(&in_balance), px, py)
        } else {
            compute_amount_stable(balance::value(&in_balance), px, py, pool.stable.x_scale, pool.stable.y_scale, pool.stable.amp)
        };

        balance::join(&mut pool.balance.x, in_balance);

        let out_balance = balance::split(&mut pool.balance.y, out_amount);
        out_balance
    }

    fun swap_y_to_x_direct_no_fee_impl<X, Y>(pool: &mut Pool<X, Y>, in_balance: Balance<Y>): Balance<X> {
        let (px, py, _) = get_amounts(pool);
        assert!(px > 0 && py > 0, EReservesEmpty);

        // Get the output amount
        let out_amount = if (pool.pool_type == EPoolTypeV2) {
            compute_amount(balance::value(&in_balance), py, px)
        } else {
            compute_amount_stable(balance::value(&in_balance), py, px, pool.stable.y_scale, pool.stable.x_scale, pool.stable.amp)
        };

        balance::join(&mut pool.balance.y, in_balance);
        let out_balance = balance::split(&mut pool.balance.x, out_amount);

        out_balance
    }

    fun increase_lsp_supply<X, Y>(pool: &mut Pool<X, Y>, amount: u64, start_epoch: u64, end_epoch: u64, boost_multiplier: u64, ctx: &mut TxContext): PoolLsp<X, Y> {
        pool.lsp_supply = pool.lsp_supply + amount;
        
        // Store the ampt inside the lsp
        let (pool_x, pool_y, pool_lsp) = get_amounts(pool);
        let lsp = PoolLsp<X, Y> {
            id: object::new(ctx),
            pool_id: object::uid_to_inner(&pool.id),
            value: amount,
            pool_x: pool_x,
            pool_y: pool_y,
            pool_lsp: pool_lsp,
            pool_mining_ampt: pool.mining.ampt,
            start_epoch: start_epoch,
            end_epoch: end_epoch,
            boost_multiplier: boost_multiplier
        };

        // Increase the mining apt amount
        vpt::add_amount(&mut pool.mining.ampt, (amount as u256) * (boost_multiplier as u256));

        lsp
    }

    fun increase_pool_lsp_info<X, Y>(pool: &mut Pool<X, Y>, amount: u64, boost_multiplier: u64) {
        if (amount > 0) {
            // Increase the mining apt amount
            pool.lsp_supply = pool.lsp_supply + amount;
            vpt::add_amount(&mut pool.mining.ampt, (amount as u256) * (boost_multiplier as u256));
        }
    }

    fun remove_lsp_supply<X, Y>(pool: &mut Pool<X, Y>, lsp: PoolLsp<X, Y>, amount: u64, ctx: &mut TxContext): PoolLsp<X, Y> {
        // Get the minimum
        let amount = math::min(lsp.value, amount);
        let boost_multiplier = lsp.boost_multiplier;

        // Decrease the supply
        pool.lsp_supply = pool.lsp_supply - amount;
        vpt::dec_amount(&mut pool.mining.ampt, (amount as u256) * (boost_multiplier as u256));

        let new_lsp = PoolLsp<X, Y> {
            id: object::new(ctx),
            pool_id: lsp.pool_id,
            value: lsp.value - amount,
            pool_x: lsp.pool_x,
            pool_y: lsp.pool_y,
            pool_lsp: lsp.pool_lsp,
            pool_mining_ampt: lsp.pool_mining_ampt,
            start_epoch: lsp.start_epoch,
            end_epoch: lsp.end_epoch,
            boost_multiplier: lsp.boost_multiplier
        };

        // Delete origin lsp
        let PoolLsp<X, Y> { id: id, pool_id: _, value: _, pool_x: _, pool_y: _, pool_lsp: _, pool_mining_ampt: _, start_epoch: _, end_epoch: _, boost_multiplier: _ } = lsp;
        object::delete(id);
        
        // Return new lsp
        new_lsp
    }

    fun destroy_zero_lsp<X, Y>(lsp: PoolLsp<X, Y>) {
        assert!(lsp.value == 0, EInvalidParameter);
        let PoolLsp<X, Y> { id: id, pool_id: _, value: _, pool_x: _, pool_y: _, pool_lsp: _, pool_mining_ampt: _, start_epoch: _, end_epoch: _, boost_multiplier: _ } = lsp;
        object::delete(id);
    }

    fun update_pool_mining<X, Y>(pool: &mut Pool<X, Y>, clock: &Clock) {
        if (pool.mining.speed > 0) {
            let current_epoch = utils::get_epoch(clock);
            if (current_epoch > pool.mining.last_epoch) {
                let depoch = current_epoch - pool.mining.last_epoch;
                pool.mining.last_epoch = current_epoch;

                let inc_amount = (depoch as u256) * pool.mining.speed;
                if (vpt::amount(&pool.mining.ampt) > 0) {
                    vpt::add_sum(&mut pool.mining.ampt, inc_amount);
                }
            }
        }
    }

    fun get_th_reward_start_and_end_epoch(current_epoch: u64, nepoch: u64): (u64, u64) {
        let start_epoch = (current_epoch / nepoch) * nepoch;
        let end_epoch = start_epoch + nepoch - 1;
        (start_epoch, end_epoch) 
    }
    // ============================================= Utilities =============================================

    // ============================================= Stable Swap Utilities =============================================

    fun ss_compute_next_d(amp: u256, d_init: u256, d_prod: u256, sum_x: u256): u256 {
        let n = (STABLESWAP_N_COINS as u256);
        let ann = (amp * n); // ann = amp * N_COINS
        let leverage = (sum_x * ann); // leverage = sum_x * ann
        let numerator = d_init * ((d_prod * n) + leverage);
        let denominator = d_init * (ann - (1 as u256)) + d_prod * (n + (1 as u256));
        numerator / denominator
    }

    fun ss_compute_d(amount_a: u256, amount_b: u256, amp: u256): u256 {
        let sum_x = amount_a + amount_b;
        if (sum_x == (0 as u256)) {
            return (0 as u256)
        };

        let amount_a_times_coins = amount_a * (STABLESWAP_N_COINS as u256);
        let amount_b_times_coins = amount_b * (STABLESWAP_N_COINS as u256);

        let d_prev;
        let d = sum_x;

        let counter = 0;
        while (counter < 255) {
            let d_prod = d;
            d_prod = d_prod * d / amount_a_times_coins;
            d_prod = d_prod * d / amount_b_times_coins;
            d_prev = d;
            d = ss_compute_next_d(amp, d, d_prod, sum_x);

            if (abs_sub(d, d_prev) <= (1 as u256)) {
                break
            };

            counter = counter + 1;
        };

        assert!(counter != 255, EComputationError);
        d
    }

    fun ss_compute_y(x: u256, d: u256, amp: u256): u256 {
        let n = (STABLESWAP_N_COINS as u256);
        let ann = amp * n;

        // sum' = prod' = x
        // c =  D ** (n + 1) / (n ** (2 * n) * prod' * A)
        let c = (d * d) / (x * n);
        let c = (c * d) / (ann * n);
        // b = sum' - (A*n**n - 1) * D / (A * n**n)
        let b = (d /  ann) + x;

        // Solve for y by approximating: y**2 + b*y = c
        let y_prev: u256;
        let y = d;

        let counter = 0;
        while (counter < 255) {
            y_prev = y;
            // y = (y * y + c) / (2 * y + b - d);
            y = (y * y + c) / (y * (2 as u256) + b - d);
            
            if (abs_sub(y, y_prev) <= (1 as u256)) {
                break
            };

            counter = counter + 1;
        };

        assert!(counter != 255, EComputationError);
        y
    }

    fun ss_swap_to(source_amount: u256, swap_source_amount: u256, swap_destination_amount: u256, amp: u256): u256 {
        let (dy, d_0) = ss_swap_to_internal(source_amount, swap_source_amount, swap_destination_amount, amp);
        let d_1 = ss_compute_d(
            source_amount +  swap_source_amount,
            swap_destination_amount + dy,
            amp
        );
        assert!(d_1 >= d_0, EComputationError);
        dy
    }

    fun ss_swap_to_internal(source_amount: u256, swap_source_amount: u256, swap_destination_amount: u256, amp: u256): (u256, u256) {
        // Returns the dy and d with previous amount
        let d = ss_compute_d(swap_source_amount, swap_destination_amount, amp);
        let y = ss_compute_y((swap_source_amount + source_amount), d, amp);
        // https://github.com/curvefi/curve-contract/blob/b0bbf77f8f93c9c5f4e415bce9cd71f0cdee960e/contracts/pool-templates/base/SwapTemplateBase.vy#L466
        let dy = (swap_destination_amount - y) - (1 as u256);
        (dy, d)
    }
    
    fun ss_compute_mint_amount_for_deposit(
        deposit_amount_a: u256, 
        deposit_amount_b: u256, 
        swap_amount_a: u256, 
        swap_amount_b: u256,
        pool_token_supply: u256,
        amp: u256
    ): u256 {
        // Initial invariant
        let d_0 = ss_compute_d(swap_amount_a, swap_amount_b, amp);
        
        let new_balances_0 = swap_amount_a + deposit_amount_a;
        let new_balances_1 = swap_amount_b + deposit_amount_b;
        
        // Invariant after change
        let d_1 = ss_compute_d(new_balances_0, new_balances_1, amp);

        if (d_1 <= d_0) {
            (0 as u256)
        }
        else {
            // d1 / (p + dp) >= d0 / p
            // ==> d1 * p >= d0 * (p + dp)
            // ==> (d1 - d0) p >= d0 dp
            // ==> dp <= (d1 - d0) p / d0
            // ==> dp = Floor[(d1 - d0) p / d0] <= (d1 - d0) p / d0
            let amount = pool_token_supply * (d_1 - d_0) / d_0;
            ss_validate_lsp_value_increase(d_0, d_1, pool_token_supply, (pool_token_supply + amount));
            amount
        }
    }

    fun ss_compute_withdraw_one(
        pool_token_amount: u256,
        pool_token_supply: u256,
        swap_base_amount: u256,  // Same denomination of token to be withdrawn
        swap_quote_amount: u256, // Counter denomination of token to be withdrawn
        amp: u256
    ): u256 {
        let d_0 = ss_compute_d(swap_base_amount, swap_quote_amount, amp);
        
        let d_1 = d_0 - (pool_token_amount * d_0) / pool_token_supply;
        let new_swap_base_amount = ss_compute_y(swap_quote_amount, d_1, amp);

        let dy = swap_base_amount - (new_swap_base_amount + (1 as u256));

        ss_validate_lsp_value_increase(d_0, d_1, pool_token_supply, (pool_token_supply - pool_token_amount));

        dy
    }

    fun ss_compute_withdraw(
        pool_token_amount: u256,
        pool_token_supply: u256,
        swap_base_amount: u256,
        swap_quote_amount: u256,
        amp: u256
    ): (u256, u256) {
        // Note: it could be simple without validation but we currently validate for every withdraw
        let d_0 = ss_compute_d(swap_base_amount, swap_quote_amount, amp);

        let swap_base_removed = (pool_token_amount * swap_base_amount) / pool_token_supply;
        let swap_quote_removed = (pool_token_amount * swap_quote_amount) /  pool_token_supply;

        let new_swap_base_amount = swap_base_amount - swap_base_removed;
        let new_swap_quote_amount = swap_quote_amount - swap_quote_removed;

        let d_1 = ss_compute_d(new_swap_base_amount, new_swap_quote_amount, amp);

        ss_validate_lsp_value_increase(d_0, d_1, pool_token_supply, (pool_token_supply - pool_token_amount));

        (swap_base_removed, swap_quote_removed)
    }

    fun ss_check_lsp_value_increase(d_0: u256, d_1: u256, lsp_0: u256, lsp_1: u256): bool {
        (d_1 / lsp_1) >= (d_0 / lsp_0)
    }

    fun ss_validate_lsp_value_increase(d_0: u256, d_1: u256, lsp_0: u256, lsp_1: u256) {
        // Validate the d per lsp not decreased
        assert!(ss_check_lsp_value_increase(d_0, d_1, lsp_0, lsp_1), EComputationError);
    }
    // ============================================= Stable Swap Utilities =============================================


    // ============================================= Misc =============================================
    fun abs_sub(a: u256, b: u256): u256 {
        if (a < b) { b - a } else { a - b }
    }
    // ============================================= Misc =============================================

    // ============================================= Implementations =============================================

    fun init_impl(ctx: &mut TxContext) {
        transfer::transfer(
            SwapCap {  
                id: object::new(ctx),
                registry_id: option::none<ID>(),
            }, 
            tx_context::sender(ctx)
        );
    }

    public fun do_change_owner<X, Y>(_: &SwapCap, pool: &mut Pool<X, Y>, owner: address, _ctx: &mut TxContext) {
        pool.owner = owner;
    }

    public fun do_create_registry(cap: &mut SwapCap, th_rewrad_epoch: u64, boost_multiplier_data: vector<u64>, ctx: &mut TxContext) {
        assert!(th_rewrad_epoch >= 1, EInvalidParameter);

        // Check the registry
        assert!(option::is_none(&cap.registry_id), EPoolRegistryAlreadyCreated);

        let pool_boost_multiplier_data = vector::empty<PoolBoostMultiplierData>();

        let n_boost_multiplier_data = vector::length(&boost_multiplier_data);
        assert!(n_boost_multiplier_data % 2 == 0, EInvalidParameter);
        let i = 0; while (i < n_boost_multiplier_data) {
            let epoch = *vector::borrow(&boost_multiplier_data, i);
            let boost_multiplier = *vector::borrow(&boost_multiplier_data, i + 1);
            vector::push_back(&mut pool_boost_multiplier_data, PoolBoostMultiplierData { epoch: epoch, boost_multiplier: boost_multiplier } );
            i = i + 2;  
        };

        let registry_uid = object::new(ctx);
        let registry_id = object::uid_to_inner(&registry_uid);
        option::fill(&mut cap.registry_id, registry_id);

        // Generate the pool registry
        let pr = PoolRegistry {
            id: registry_uid,
            version: VERSION,
            pool_counter: 0,
            pool_no_admin: PoolNoAdminSetupInfo {
                allowance: true,
                fee_direction: EFeeDirectionY, // Set to the base coin
                admin_fee: 2, // Default set to 0.02%
                lp_fee: 25, // Default set to 0.25%
                th_fee: 3, // Default set to 0.03%
                withdraw_fee: 10 // Default set to 0.1%
            },
            pool_th_reward_nepoch: th_rewrad_epoch,
            pool_boost_multiplier_data: pool_boost_multiplier_data
        };

        transfer::share_object(pr);
    }

    /// Create new `Pool` for token pair X & Y. Each Pool holds a `Coin<X>`
    /// and a `Coin<Y>`. Swaps are available in both directions.
    /// 
    /// **Note**: We don't force the order of the coin type X and Y. So that
    /// we could create both SUI/USDC pool and USDC/SUI. The reasons for such
    /// design are:
    /// 
    /// 1. We only allow admin to create pool, admin could take care of this.
    /// 
    /// 2. We generally regards the X token as quote token and Y token as bsae 
    /// token. And Pool<X,Y> denotes a pool with quote token for X and base token
    /// for Y. And we could define the "price" (X relative to Y) without ambiguity.
    public fun do_create_pool<X, Y>(
        _: &SwapCap,
        reg: &mut PoolRegistry, 
        farm: &TokenFarm,
        pool_type: u8,
        pool_th_reward_type: u8,
        fee_direction: u8,
        admin_fee: u64,
        lp_fee: u64,
        th_fee: u64,
        withdraw_fee: u64,
        stable_amp: u64,
        stable_x_decimal: u8,
        stable_y_decimal: u8,
        bx: u64,
        by: u64,
        freeze_bit: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(reg.version== VERSION, EVersionNotMatched);
        create_pool_impl<X, Y>(
            reg, farm, pool_type, pool_th_reward_type, fee_direction, admin_fee, lp_fee, th_fee, withdraw_fee, stable_amp, stable_x_decimal, stable_y_decimal, bx, by, freeze_bit, clock, ctx
        );
    }

    /// Change the fee of a pool
    public fun do_change_fee<X, Y>(_: &SwapCap, pool: &mut Pool<X, Y>, new_admin_fee: u64, new_lp_fee: u64, new_th_fee: u64, _: &mut TxContext) {
        assert!(pool.version== VERSION, EVersionNotMatched);
        let admin_fee = if (new_admin_fee == U64_MAX_U64) { pool.fee.admin } else { new_admin_fee };
        let lp_fee = if (new_lp_fee == U64_MAX_U64) { pool.fee.lp } else { new_lp_fee };
        let th_fee = if (new_th_fee == U64_MAX_U64) { pool.fee.th } else { new_th_fee };

        assert!(lp_fee + admin_fee + th_fee < BPS_SCALING_U64, EWrongFee);
        pool.fee.lp = lp_fee;
        pool.fee.admin = admin_fee;
        pool.fee.th = th_fee;  
    }

    public fun do_change_basis<X, Y>(_: &SwapCap, pool: &mut Pool<X, Y>, bx: u64, by: u64, _: &mut TxContext) {
        assert!(pool.version== VERSION, EVersionNotMatched);
        pool.balance.bx = bx;
        pool.balance.by = by;
    }

    public fun do_set_pool_freeze<X, Y>(_: &SwapCap, pool: &mut Pool<X, Y>, freeze: u8) {
        assert!(pool.version== VERSION, EVersionNotMatched);
        pool.freeze = freeze;
    }

    /// Redeem the balance to the Coin<X> and Coin<Y> and transfer to the admin
    public fun do_redeem_admin_balance<X, Y>(_: & SwapCap, pool: &mut Pool<X, Y>, x_amount: u64, y_amount: u64, ctx: &mut TxContext) {
        assert!(pool.version== VERSION, EVersionNotMatched);
        let x_amount = math::min(balance::value(&pool.balance.x_admin), x_amount);
        let y_amount = math::min(balance::value(&pool.balance.y_admin), y_amount);
        let sender = tx_context::sender(ctx);

        transfer::public_transfer(
            coin::from_balance(balance::split(&mut pool.balance.x_admin, x_amount), ctx),
            sender
        );
        transfer::public_transfer(
            coin::from_balance(balance::split(&mut pool.balance.y_admin, y_amount), ctx),
            sender
        );
    }

    public fun do_change_pool_mining_speed<X, Y>(_: &SwapCap, token_cap: &TokenCap, pool: &mut Pool<X, Y>, speed: u64) {
        assert!(pool.version== VERSION, EVersionNotMatched);
        pool.mining.speed = (speed as u256);

        // Check and set the permission so that we can mine
        if (option::is_none(&pool.mining.permission)) {
            let pr = token::token_cap_cp_token_bank_permission(token_cap);
            option::fill(&mut pool.mining.permission, pr);
        };
    }

    public fun do_create_pool_no_admin<X, Y>(reg: &mut PoolRegistry, farm: &TokenFarm, clock: &Clock, ctx: &mut TxContext) {
        assert!(reg.version== VERSION, EVersionNotMatched);
        let na = &reg.pool_no_admin;
        create_pool_impl<X, Y>(
            reg,  // reg
            farm, // farm
            EPoolTypeV2,  // pool_type
            ETokenHolderRewardTypeBalance, // pool_th_reward_type
            na.fee_direction,  // fee_direction
            na.admin_fee,  // admin_fee
            na.lp_fee,  // lp_fee
            na.th_fee,  // th_fee
            na.withdraw_fee, // withdraw_fee
            0,  // stable_amp
            0,  // stable_x_decimal
            0,  // stable_y_decimal
            0, // bx,
            0, // by,
            0, // no freeze
            clock, // clock
            ctx, // ctx
        );
    }

    /// Swap x amount of token `Coin<X>` for the `Coin<Y>` and returns Coin<Y>
    public fun do_swap_x_to_y<X, Y>(pool: &mut Pool<X, Y>, cxs: vector<Coin<X>>, in_amount: u64, min_out_amount: u64, clock: &Clock, ctx: &mut TxContext) {
        let (coinX, coinY) = do_swap_x_to_y_direct(pool, cxs, in_amount, clock, ctx);
        assert!(coin::value(&coinY) >= min_out_amount, ESlippageLimit);
        let sender = tx_context::sender(ctx);

        utils::transfer_or_destroy_zero(coinX, sender);
        utils::transfer_or_destroy_zero(coinY, sender);
    }

    public fun do_swap_x_to_y_direct<X, Y>(pool: &mut Pool<X, Y>, cxs: vector<Coin<X>>, in_amount: u64, clock: &Clock, ctx: &mut TxContext): (Coin<X>, Coin<Y>) {
        assert!(pool.version== VERSION, EVersionNotMatched);
        assert!(in_amount > 0 && vector::length(&cxs) > 0, EInvalidParameter);
        if (tx_context::sender(ctx) != pool.owner) {
            assert!((pool.freeze & EPoolFreezeSwapBit) == 0, EPoolFreeze);
        };

        // Transfer to balance and take
        let bx = coin::into_balance(utils::merge_coins(cxs, ctx));
        assert!(balance::value(&bx) >= in_amount, ENotEnoughBalance);
        
        let in_balance = balance::split(&mut bx, in_amount);

        // Collect admin fee (x)
        collect_admin_and_th_fee_x(pool, &mut in_balance);

        // Collect lp fee
        let fee_balance = collect_fee(&mut in_balance, pool.fee.lp);

        // Swap
        let out_balance = swap_x_to_y_direct_no_fee_impl(pool, in_balance);
        let out_amount = balance::value(&out_balance);

        // Collect admin fee (y)
        collect_admin_and_th_fee_y(pool, &mut out_balance);

        // Rejoin the fee balance
        balance::join(&mut pool.balance.x, fee_balance);

        // Check whether we need to use deposit token in `x_th` and `y_th` to buy back additional token using automatically back buy
        process_auto_buyback(pool);

        //  Update token mining
        update_pool_mining(pool, clock);

        // Transfer back the cx if it is not empty
        let coinX = coin::from_balance(bx, ctx);
        let coinY = coin::from_balance(out_balance, ctx);

        // Event and statistics
        event::emit(SwapTokenEvent<X, Y> {
            pool_index: pool.index,
            x_to_y: true,
            in_amount: in_amount,
            out_amount: coin::value(&coinY)
        });

        let trade_epoch = utils::get_epoch(clock);

        // Summaries the total trade volume
        pool.total_trade.x = pool.total_trade.x + (in_amount as u128);
        pool.total_trade.y = pool.total_trade.y + (out_amount as u128);

        if (trade_epoch != pool.trade_epoch) {
            pool.total_trade.x_last_epoch = pool.total_trade.x_current_epoch;
            pool.total_trade.y_last_epoch = pool.total_trade.y_current_epoch;
            pool.total_trade.x_current_epoch = (in_amount as u128);
            pool.total_trade.y_current_epoch = (out_amount as u128);
            pool.trade_epoch = trade_epoch;

            let (pool_x, pool_y, pool_lsp) = get_amounts(pool);
            event::emit(SnapshotEvent<X, Y> { 
                pool_index: pool.index,
                x: pool_x,
                y: pool_y,
                lsp: pool_lsp,
            });

        } else {
            pool.total_trade.x_current_epoch = pool.total_trade.x_current_epoch + (in_amount as u128);
            pool.total_trade.y_current_epoch = pool.total_trade.y_current_epoch + (out_amount as u128);
        };

        (coinX, coinY)
    }

    /// Swap y amount of token `Coin<Y>` for the `Coin<X>` and returns Coin<X>
    public fun do_swap_y_to_x<X, Y>(pool: &mut Pool<X, Y>, cys: vector<Coin<Y>>, in_amount: u64, min_out_amount: u64, clock: &Clock, ctx: &mut TxContext) {
        let (coinY, coinX) = do_swap_y_to_x_direct(pool, cys, in_amount, clock, ctx);
        assert!(coin::value(&coinX) >= min_out_amount, ESlippageLimit);
        let sender = tx_context::sender(ctx);

        utils::transfer_or_destroy_zero(coinY, sender);
        utils::transfer_or_destroy_zero(coinX, sender);
    }

    public fun do_swap_y_to_x_direct<X, Y>(pool: &mut Pool<X, Y>, cys: vector<Coin<Y>>, in_amount: u64, clock: &Clock, ctx: &mut TxContext): (Coin<Y>, Coin<X>) {
        assert!(pool.version== VERSION, EVersionNotMatched);
        assert!(in_amount > 0 && vector::length(&cys) > 0, EInvalidParameter);
        if (tx_context::sender(ctx) != pool.owner) {
            assert!((pool.freeze & EPoolFreezeSwapBit) == 0, EPoolFreeze);
        };

        let by = coin::into_balance(utils::merge_coins(cys, ctx));
        assert!(balance::value(&by) >= in_amount, ENotEnoughBalance);

        let in_balance = balance::split(&mut by, in_amount);

        // Collect admin fee (y)
        collect_admin_and_th_fee_y(pool, &mut in_balance);

        // Collect lp fee
        let fee_balance = collect_fee(&mut in_balance, pool.fee.lp);

        // Swap
        let out_balance = swap_y_to_x_direct_no_fee_impl(pool, in_balance);
        let out_amount = balance::value(&out_balance);

        // Collect admin fee (x)
        collect_admin_and_th_fee_x(pool, &mut out_balance);
        
        // Rejoin the fee balance
        balance::join(&mut pool.balance.y, fee_balance);

        // Check whether we need to use deposit token in `x_th` and `y_th` to buy back additional token using automatically back buy
        process_auto_buyback(pool);

        //  Update token mining
        update_pool_mining(pool, clock);

        // Transfer back the cx if it is not empty
        let coinY = coin::from_balance(by, ctx);
        let coinX = coin::from_balance(out_balance, ctx);

        event::emit(SwapTokenEvent<X, Y> {
            pool_index: pool.index,
            x_to_y: false,
            in_amount: in_amount,
            out_amount: coin::value(&coinX)
        });

        let trade_epoch = utils::get_epoch(clock);

        pool.total_trade.y = pool.total_trade.y + (in_amount as u128);
        pool.total_trade.x = pool.total_trade.x + (out_amount as u128);
        if (trade_epoch != pool.trade_epoch) {
            pool.total_trade.y_last_epoch = pool.total_trade.y_current_epoch;
            pool.total_trade.x_last_epoch = pool.total_trade.x_current_epoch;
            pool.total_trade.y_current_epoch = (in_amount as u128);
            pool.total_trade.x_current_epoch = (out_amount as u128);
            pool.trade_epoch = trade_epoch;

            let (pool_x, pool_y, pool_lsp) = get_amounts(pool);
            event::emit(SnapshotEvent<X, Y> { 
                pool_index: pool.index,
                x: pool_x,
                y: pool_y,
                lsp: pool_lsp
            });

        } else {
            pool.total_trade.y_current_epoch = pool.total_trade.y_current_epoch + (in_amount as u128);
            pool.total_trade.x_current_epoch = pool.total_trade.x_current_epoch + (out_amount as u128);
        };

        (coinY, coinX)
    }

    /// Add liquidity to the `Pool`. Sender needs to provide both
    /// `Coin<X>` and `Coin<Y>`, and in exchange he gets `Coin<LSP>` liquidity provider tokens.
    public fun do_add_liquidity<X, Y>(pool: &mut Pool<X, Y>, x: vector<Coin<X>>, y: vector<Coin<Y>>, in_x_amount: u64, in_y_amount: u64, unlock_epoch: u64, clock: &Clock, ctx: &mut TxContext) {
        let lsp_coin = do_add_liquidity_direct(pool, x, y, in_x_amount, in_y_amount, unlock_epoch, clock, ctx);
        transfer::transfer(
            lsp_coin,
            tx_context::sender(ctx)
        );
    }

    public fun do_add_liquidity_direct<X, Y>(pool: &mut Pool<X, Y>, x: vector<Coin<X>>, y: vector<Coin<Y>>, in_x_amount: u64, in_y_amount: u64, unlock_epoch: u64, clock: &Clock, ctx: &mut TxContext): PoolLsp<X, Y> {
        add_liquidity_direct_impl(pool, x, y, in_x_amount, in_y_amount, unlock_epoch, false, clock, ctx)
    }

    /// Remove liquidity from the `Pool` by burning `Coin<LSP>`. Returns `Coin<X>` and `Coin<Y>`.
    public fun do_remove_liquidity<X, Y>(pool: &mut Pool<X, Y>, bank: &mut TokenBank, lsp: PoolLsp<X, Y>, lsp_amount: u64, clock: &Clock, ctx: &mut TxContext) {
        remove_liquidity_impl(pool, bank, lsp, lsp_amount, 2, false, clock, ctx);
    }

    public fun do_remove_liquidity_force<X, Y>(pool: &mut Pool<X, Y>, bank: &mut TokenBank, lsp: PoolLsp<X, Y>, signature: vector<u8>, clock: &Clock, ctx: &mut TxContext) {
        let pk_opt = token::token_bank_get_public_key(bank);
        assert!(option::is_some(&pk_opt), EPermissionDenied);
        let pk = option::borrow(&pk_opt);

        // Verify
        let msg = b"remove-liquidity-force"; // Append the name
        vector::append(&mut msg, bcs::to_bytes(&object::uid_to_inner(&lsp.id))); // Append the `pool lsp id`
        let verified = ed25519_verify(&signature, pk, &msg);
        assert!(verified, EPermissionDenied);

        let lsp_amount = lsp.value;
        remove_liquidity_impl(pool, bank, lsp, lsp_amount, 2, true, clock, ctx);
    }

    // Note: Test case needs to include the following
    // 1. Generate a pool and try do some swapping, then generate a series of users that is going to redeem token, multiple times.
    // 2. Forbid user to claim reward if if stake token after th reward
    // 3. Forbid user to recalim staked token with the same token
    public fun do_claim_th_reward<X, Y>(farm: &TokenFarm, st: &mut StakedToken, pool: &mut Pool<X, Y>, clock: &Clock, ctx: &mut TxContext) {
        let code = claim_th_reward_impl(farm, st, pool, clock, ctx);
        assert!(code == 0, code);
    }

    public fun do_update_th_reward<X, Y>(farm: &TokenFarm, pool: &mut Pool<X, Y>, clock: &Clock, _ctx: &mut TxContext) {
        update_th_reward_impl(farm, pool, utils::get_epoch(clock));
    }

    // ============================================= Implementations =============================================
}