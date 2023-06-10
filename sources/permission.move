// Copyright (c) 2023, Vivid Network Contributors
// SPDX-License-Identifier: Apache-2.0

/// Simple permission system
module suiswap::permission {
    
    friend suiswap::pool;
    friend suiswap::TOKEN;

    // Nothing but a simple permission
    struct Permission<phantom T> has store { }

    public(friend) fun new<T>(): Permission<T> {
        Permission<T> { }
    }

    /// Copy the permission
    public fun cp<T>(_: &Permission<T>): Permission<T> {
        new()
    }

    /// Destory the permission
    public fun destroy<T>(x: Permission<T>) {
        let Permission { } = x;
    }
}