// Copyright (c) 2023, Vivid Network Contributors
// SPDX-License-Identifier: Apache-2.0

/// Defines the `SBalance` type - a simple wrapper for capturing the initial supply 
/// and current left balance into a simple struct and provides some basic useful functionality
module suiswap::sbalance {

    use sui::balance::{ Self, Balance };

    /// Not enough balance to split the amount
    const ESBalanceNotEnoughBalanceForSplit: u64 = 164001;
    /// Invalid "part" parameter input
    // const ESBalanceInvalidPartParameterInput: u64 = 164002;
    /// Cannot delete sbalance, still have balance inside
    const ESBalanceDeleteZeroError: u64 = 164003;

    struct SBalance<phantom T> has store {
        /// The curret left balance
        balance: Balance<T>,
        /// The original supply
        supply: u64,
    }

    public fun value<T>(x: &SBalance<T>): u64 { balance::value(&x.balance) }
    public fun supply<T>(x: &SBalance<T>): u64 { x.supply }

    // public fun sbalance<T>(balance: Balance<T>, supply: u64): SBalance<T> {
    //     SBalance<T> { balance: balance, supply: supply }
    // }

    /// Generate a SBalance<T> from Balance<T>
    public fun from_balance<T>(balance: Balance<T>): SBalance<T> { 
        let supply = balance::value(&balance);
        SBalance {
            balance: balance,
            supply: supply
        }
    }

    /// Transfer SBalance<T> into Balance<T>
    public fun into_balance<T>(x: SBalance<T>): Balance<T> {
        let SBalance { balance: balance, supply: _ } = x;
        balance
    }

    /// Increase the SBalance from the balance
    public fun increase<T>(x: &mut SBalance<T>, balance: Balance<T>) {
        let join_supply = balance::value(&balance);
        balance::join(&mut x.balance, balance);
        x.supply = x.supply + join_supply;
    }

    /// Split a specified amount from SBalance without changing the original supply
    public fun split<T>(x: &mut SBalance<T>, amount: u64): Balance<T> {
        assert!(value(x) >= amount, ESBalanceNotEnoughBalanceForSplit);
        let split_balance = balance::split(&mut x.balance, amount);
        split_balance
    }

    public fun split_all<T>(x: &mut SBalance<T>): Balance<T> {
        let amount = value(x);
        split(x, amount)
    }

    /// Remove zero SBalance
    public fun destroy_zero<T>(x: SBalance<T>) {
        assert!(value(&x) == 0, ESBalanceDeleteZeroError);
        let SBalance { balance: balance, supply: _} = x;
        balance::destroy_zero(balance);
    }

    #[test_only] use sui::balance::{ destroy_for_testing as destroy_balance, create_for_testing as mint_balance };
    #[test_only] struct X { }
    #[test_only] fun mint<T>(amount: u64): SBalance<T> { from_balance(balance::create_for_testing<T>(amount)) }
    #[test_only] fun destroy<T>(s: SBalance<T>) {
        let SBalance { balance: b, supply: _ } = s; 
        balance::destroy_for_testing(b);
    }

    #[test] fun t_sbalance_value_1() { 
        let a = mint<X>(100);
        let b = mint<X>(0);
        let c = mint<X>(18446744073709551615);
        assert!(value(&a) == 100, 0);
        assert!(value(&b) == 0, 0);
        assert!(value(&c) == 18446744073709551615, 0);
        destroy(a);
        destroy(b);
        destroy(c);
    }

    #[test] fun t_sbalance_supply_1() {
        let a = mint<X>(18446744073709551615);
        assert!(supply(&a) == 18446744073709551615, 0);
        let b = split(&mut a, 558992244657865200);
        assert!(balance::value(&b) == 558992244657865200, 0);
        assert!(supply(&a) == 18446744073709551615, 0);
        assert!(value(&a) == 18446744073709551615 - 558992244657865200, 0);
        destroy(a);
        destroy_balance(b);
    }

    #[test] fun t_sbalance_from_balance_1() {
        let x = from_balance(mint_balance<X>(10));
        assert!(value(&x) == 10, 0);
        assert!(supply(&x) == 10, 0);

        let y = from_balance(mint_balance<X>(0));
        assert!(value(&y) == 0, 0);
        assert!(supply(&y) == 0, 0);

        destroy(x);
        destroy(y);
    }

    #[test] fun t_sbalance_into_balance_1() {
       let x = into_balance(from_balance(mint_balance<X>(10)));
       let y = into_balance(from_balance(mint_balance<X>(0)));
       assert!(balance::value(&x) == 10, 0);
       assert!(balance::value(&y) == 0, 0);
       destroy_balance(x);
       destroy_balance(y);
    }

    #[test] fun t_sbalance_increase_1() {
        let x = from_balance(mint_balance<X>(10000));
        let b = split(&mut x, 5000);
        increase(&mut x, mint_balance<X>(20000));
        let c = split(&mut x, 5000);

        assert!(value(&x) == 20000, 0);
        assert!(supply(&x) == 30000, 0);
        destroy(x);
        destroy_balance(b);
        destroy_balance(c);
    }

    #[test] fun t_sbalance_split_1() {
        let x = from_balance(mint_balance<X>(10000));
        let b = split(&mut x, 5000);
        assert!(value(&x) == 5000, 0);
        assert!(supply(&x) == 10000, 0);
        let c = split(&mut x, 5000);
        assert!(value(&x) == 0, 0);
        assert!(supply(&x) == 10000, 0);
        destroy(x);
        destroy_balance(b);
        destroy_balance(c);
    }

    #[test] fun t_sbalance_split_all_1() {
        let x = from_balance(mint_balance<X>(10000));
        let xall = split_all(&mut x);
        assert!(value(&x) == 0, 0);
        assert!(supply(&x) == 10000, 0);
        assert!(balance::value(&xall) == 10000, 0);
        destroy(x);
        destroy_balance(xall);
    }

    #[test] fun t_sbalance_split_all_2() {
        let x = from_balance(mint_balance<X>(0));
        let xall = split_all(&mut x);
        assert!(value(&x) == 0, 0);
        assert!(supply(&x) == 0, 0);
        assert!(balance::value(&xall) == 0, 0);
        destroy(x);
        destroy_balance(xall);
    }

    #[test] #[expected_failure(abort_code = ESBalanceNotEnoughBalanceForSplit)] fun t_sbalance_split_2() {
        let x = from_balance(mint_balance<X>(10000));
        let b = split(&mut x, 5000);
        let c = split(&mut x, 5001);
        destroy(x);
        destroy_balance(b);
        destroy_balance(c);
    }

    #[test] fun t_sbalance_delete_zero_1() {
        let x = mint<X>(0);
        destroy_zero(x);
    }

    #[test] fun t_sbalance_delete_zero_2() {
        let x = mint<X>(1000);
        let a = split(&mut x, 1000);
        destroy_zero(x);
        destroy_balance(a);
    }
    
    #[test] #[expected_failure(abort_code = ESBalanceDeleteZeroError)] fun t_sbalance_delete_zero_3() {
        let x = mint<X>(1000);
        let a = split(&mut x, 999);
        destroy_zero(x);
        destroy_balance(a);
    }
}