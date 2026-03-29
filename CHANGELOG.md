# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-03-24
### Added
- **Multi-region Architecture**: Added Terraform for `us-east-1` and `ap-south-1`.
- **AutoFailoverManager**: Implemented strike threshold (3 strikes) and auto-failover to secondary.
- **Replication Checks**: Added support for acknowledging MySQL replication on write (`strict` mode).
- **Auto-Failback**: Support for automatic recovery back to primary when original DB is healthy.
- **Flask API**: Standardized endpoints for status, replication, and manual failover.
- **Diagnostics**: Detailed Excalidraw diagram for architecture overview.
- **Repository Maintenance**: License (MIT), Contributing, Code of Conduct, Security Policy.

### Fixed
- Fixed issue where Postgres wasn't responding (converted system to MySQL).
- Resolved Python 3.14 compatibility in Flask runtime.

---
*HealSync: Disaster Recovery Simplified.*
