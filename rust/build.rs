fn main() {
    // `TRADING_CHALLENGE_CREDENTIAL_KEY` is read with `option_env!` in src/secrets.rs, which
    // resolves at compile time. Without this, Cargo would happily reuse a
    // cached build after the variable changed and silently ship the fallback
    // key. See the security notes in src/secrets.rs.
    println!("cargo:rerun-if-env-changed=TRADING_CHALLENGE_CREDENTIAL_KEY");
}
