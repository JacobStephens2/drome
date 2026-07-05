//! drome-core: rules engine, append-only event log, day-boundary math, projections.
//! See docs/ARCHITECTURE.md for the pinned contracts.

pub const CHALLENGE_LENGTH_DAYS: u32 = 75;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scaffold_smoke() {
        assert_eq!(CHALLENGE_LENGTH_DAYS, 75);
    }
}
