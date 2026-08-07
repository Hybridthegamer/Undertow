#!/usr/bin/env bash
# Restore the exact pinned dependencies for the Undertow LVR-recapture hook.
# These SHAs match the Programmable-tested baseline (dependency-lock.json).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p lib

pin() { # dir repo sha
  if [ ! -d "lib/$1/.git" ]; then
    git clone --filter=blob:none --no-checkout "$2" "lib/$1"
  fi
  git -C "lib/$1" fetch --depth 1 origin "$3"
  git -C "lib/$1" checkout -q "$3"
}

pin forge-std              https://github.com/foundry-rs/forge-std.git            3b20d60d14b343ee4f908cb8079495c07f5e8981
pin v4-core                https://github.com/Uniswap/v4-core.git                 59d3ecf53afa9264a16bba0e38f4c5d2231f80bc
pin v4-periphery           https://github.com/Uniswap/v4-periphery.git            ad04c9f24a170accf5ea1b2836bbafd514537ca6
pin openzeppelin-contracts https://github.com/OpenZeppelin/openzeppelin-contracts.git 21c8312b022f495ebe3621d5daeed20552b43ff9
pin uniswap-hooks          https://github.com/OpenZeppelin/uniswap-hooks.git      26dc8e53f812a1ca390d470342adb6cd8c3286ad
pin permit2                https://github.com/Uniswap/permit2.git                 cc56ad0f3439c502c246fc5cfcc3db92bb8b7219

# v4-core test utilities need its solmate submodule.
git -C lib/v4-core submodule update --init --recursive --depth 1

echo "Dependencies restored. Run: forge test   (fork suite needs MAINNET_RPC_URL)"
