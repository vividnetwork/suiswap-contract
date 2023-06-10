# Suiswap Smart Contract

The source code for https://suiswap.app

## Building & Testing

- Clone the project by running:

```
git clone git@github.com:vividnetwork/suiswap.git
```

- Initialize the submodule, it will contains the `sui` with correct git commit:

```
git submodule update --init --recursive 
```

- Build (make sure you are using the correct version of the sui cli):

```
sui move build
```