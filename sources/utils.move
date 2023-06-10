// Copyright (c) 2023, Vivid Network Contributors
// SPDX-License-Identifier: Apache-2.0

module suiswap::utils {

    use std::vector;
    use sui::pay;
    use sui::coin::{ Self, Coin };
    use sui::balance::{ Self, Supply, Balance };
    use sui::transfer;
    use sui::clock::{ Self, Clock };
    use sui::tx_context::{ Self, TxContext };
    use suiswap::ratio::{ Self, Ratio };

    const ClockEpochMultiplier: u64 = 86400u64 * 1000u64;

    /// Not enough balance for operation
    const EUtilsNotEnoughBalance: u64 = 154001;

    #[test_only] 
    public fun create_clock(ctx: &mut TxContext): Clock {
        clock::create_for_testing(ctx)
    }

    #[test_only]
    public fun destroy_clock(clock: Clock) {
        clock::destroy_for_testing(clock);
    }

    #[test_only]
    public fun next_epoch_clock(clock: &mut Clock) {
        let new_clock_time_ms = (get_epoch(clock) + 1) * ClockEpochMultiplier;
        clock::set_for_testing(clock, new_clock_time_ms);
    }

    public fun get_epoch(clock: &Clock): u64 {
        clock::timestamp_ms(clock) / ClockEpochMultiplier
    }

    public fun merge_coins<T>(cs: vector<Coin<T>>, ctx: &mut TxContext): Coin<T> {
        if (vector::length(&cs) == 0) {
            let c = coin::zero<T>(ctx);
            vector::destroy_empty(cs);
            c
        }
        else {
            let c = vector::pop_back(&mut cs);
            pay::join_vec(&mut c, cs);
            c
        }
    }

    public fun merge_coins_to_amount_and_transfer_back_rest<T>(cs: vector<Coin<T>>, amount: u64, ctx: &mut TxContext): Coin<T> {
        let c = merge_coins(cs, ctx);
        assert!(coin::value(&c) >= amount, EUtilsNotEnoughBalance);

        let c_out = coin::split(&mut c, amount, ctx);

        let sender = tx_context::sender(ctx);
        transfer_or_destroy_zero(c, sender);
        
        c_out
    }

    public fun transfer_or_destroy_zero<X>(c: Coin<X>, addr: address) {
        if (coin::value(&c) > 0) {
            transfer::public_transfer(c, addr);
        }
        else {
            coin::destroy_zero(c);
        }
    }

    public fun mint_from_supply<T>(s: &mut Supply<T>, amount: u64, recipient: address, ctx: &mut TxContext) {
        let mint_balance = balance::increase_supply(s, amount);
        let coin = coin::from_balance(mint_balance, ctx);
        transfer::public_transfer(coin, recipient);
    }

    public fun split_partial_balance<X>(balance: &mut Balance<X>, part: Ratio): Balance<X> {
        let amount = ratio::partial(part, balance::value(balance));
        let part = balance::split(balance, amount);
        part
    }

    /// Join the balance without destorying it
    public fun join_balance<X>(b1: &mut Balance<X>, b2: &mut Balance<X>) {
        let b2_amount = balance::value(b2);
        join_balance_with_amount(b1, b2, b2_amount);
    }

    public fun join_balance_with_amount<X>(b1: &mut Balance<X>, b2: &mut Balance<X>, amount: u64) {
        let b3 = balance::split(b2, amount);
        balance::join(b1, b3);
    }


    // fun pop_sub_vector<T>(v: &mut vector<T>, length: u64): vector<T> {
    //     vector::reverse(v);

    //     let w = vector::empty<T>();
    //     let len = math::min(length, vector::length(v));
        
    //     let i = 0;
    //     while (i < len) {
    //         let el = vector::pop_back(v);
    //         vector::push_back(&mut w, el);
    //         i = i + 1;  
    //     };

    //     vector::reverse(v);
    //     w
    // }

    #[test_only] use sui::coin::{mint_for_testing as mint};
    #[test_only] use sui::balance::{ create_for_testing as mint_balance, destroy_for_testing as destroy_balance };
    #[test_only] use sui::test_scenario::{
        Self as test, 
        ctx,
        next_tx as nt,
        take_from_sender as t,
        return_to_sender as r,
        has_most_recent_for_sender as h,
    };
    #[test_only] struct X { }

    #[test_only] fun tul_merge_coins_to_amount_and_transfer_back_rest(sender: address, in_amounts: vector<u64>, split_amount: u64) {
        let u_ = test::begin(@0x1);
        let u = &mut u_;

        // Generate the coins
        let cs = vector::empty<Coin<X>>();
        let in_amount = 0;
        while (vector::length(&in_amounts) > 0) {
            let c =mint<X>(
                vector::pop_back(&mut in_amounts),
                ctx(u)
            );
            in_amount = in_amount + coin::value(&c);
            vector::push_back(&mut cs, c);
        };

        nt(u, sender); {
            let c_split = merge_coins_to_amount_and_transfer_back_rest(cs, split_amount, ctx(u));
            nt(u, sender);

            assert!(coin::value(&c_split) == split_amount, 0);

            let out_amount = if (h<Coin<X>>(u)) {
                let c_out = t<Coin<X>>(u);
                let out_amount = coin::value(&c_out);
                r(u, c_out);
                out_amount
            } else {
                0
            };
            assert!(split_amount + out_amount == in_amount, 0);

            coin::burn_for_testing(c_split);
        };

        test::end(u_);
    }


    #[test]  fun t_merge_coins_to_amount_and_transfer_back_rest_case_1() { tul_merge_coins_to_amount_and_transfer_back_rest(@0x02001, vector[], 0); }
    #[test]  fun t_merge_coins_to_amount_and_transfer_back_rest_case_2() { tul_merge_coins_to_amount_and_transfer_back_rest(@0x02002, vector[1000], 0); }
    #[test]  fun t_merge_coins_to_amount_and_transfer_back_rest_case_3() { tul_merge_coins_to_amount_and_transfer_back_rest(@0x02003, vector[1000], 1); }
    #[test]  fun t_merge_coins_to_amount_and_transfer_back_rest_case_4() { tul_merge_coins_to_amount_and_transfer_back_rest(@0x02004, vector[1000], 45); }
    #[test]  fun t_merge_coins_to_amount_and_transfer_back_rest_case_5() { tul_merge_coins_to_amount_and_transfer_back_rest(@0x02005, vector[1000], 999); }
    #[test]  fun t_merge_coins_to_amount_and_transfer_back_rest_case_6() { tul_merge_coins_to_amount_and_transfer_back_rest(@0x02006, vector[1000], 1000); }
    #[test] #[expected_failure(abort_code = EUtilsNotEnoughBalance)]  fun t_merge_coins_to_amount_and_transfer_back_rest_case_7() { tul_merge_coins_to_amount_and_transfer_back_rest(@0x02007, vector[1000], 1001); }
    #[test]  fun t_merge_coins_to_amount_and_transfer_back_rest_case_8() { tul_merge_coins_to_amount_and_transfer_back_rest(@0x02008, vector[150, 10, 100, 40, 0, 700], 0); }
    #[test]  fun t_merge_coins_to_amount_and_transfer_back_rest_case_9() { tul_merge_coins_to_amount_and_transfer_back_rest(@0x02009, vector[150, 10, 100, 40, 0, 700], 1); }
    #[test]  fun t_merge_coins_to_amount_and_transfer_back_rest_case_10() { tul_merge_coins_to_amount_and_transfer_back_rest(@0x02010, vector[150, 10, 100, 40, 0, 700], 45); }
    #[test]  fun t_merge_coins_to_amount_and_transfer_back_rest_case_11() { tul_merge_coins_to_amount_and_transfer_back_rest(@0x02011, vector[150, 10, 100, 40, 0, 700], 999); }
    #[test]  fun t_merge_coins_to_amount_and_transfer_back_rest_case_12() { tul_merge_coins_to_amount_and_transfer_back_rest(@0x02012, vector[150, 10, 100, 40, 0, 700], 1000); }
    #[test] #[expected_failure(abort_code = EUtilsNotEnoughBalance)] fun t_merge_coins_to_amount_and_transfer_back_rest_case_13() { tul_merge_coins_to_amount_and_transfer_back_rest(@0x02013, vector[150, 10, 100, 40, 0, 700], 1001); }

    // #[test] fun t_pop_sub_vector() {
    //     assert!(pop_sub_vector(&mut b"test", 0) == b"", 0);
    //     assert!(pop_sub_vector(&mut b"test", 1) == b"t", 0);
    //     assert!(pop_sub_vector(&mut b"test", 2) == b"te", 0);
    //     assert!(pop_sub_vector(&mut b"test", 3) == b"tes", 0);
    //     assert!(pop_sub_vector(&mut b"test", 4) == b"test", 0);
    //     assert!(pop_sub_vector(&mut b"test", 5) == b"test", 0);
    //     assert!(pop_sub_vector(&mut b"test", 6) == b"test", 0);
    //     assert!(pop_sub_vector(&mut b"test", 100) == b"test", 0);
    //     assert!(pop_sub_vector(&mut b"", 0) == b"", 0);
    //     assert!(pop_sub_vector(&mut b"", 1) == b"", 0);
    //     assert!(pop_sub_vector(&mut b"", 100) == b"", 0);
    // }

    #[test_only] fun tu_utils_join_balance(v1: u64, v2: u64) {
        let b1 = mint_balance<X>(v1);
        let b2 = mint_balance<X>(v2);
        join_balance(&mut b1, &mut b2);
        assert!(balance::value(&b1) == v1 + v2, 0);
        assert!(balance::value(&b2) == 0, 0);
        destroy_balance(b1);
        destroy_balance(b2);
    }

    #[test] fun t_utils_join_balance_1() {
        tu_utils_join_balance(1000, 2000);
        tu_utils_join_balance(0, 1000);
        tu_utils_join_balance(0, 0);
        tu_utils_join_balance(9223372036854775807, 9223372036854775807);
    }

    // #[test] fun t_compute_overflow() {
    //     let a: u64 = 18446744073709551615u64;
    //     let a2: u128 = (a as u128) * (a as u128);
    //     let a3: u256 = (a as u256) * (a as u256) * (a as u256);

    //     let a3_u128 = (a3 as u128);
    //     let a2_u64 = (a2 as u64);
    //     assert!(a3_u128 >= (a2_u64 as u128), 0);
    // }
}

