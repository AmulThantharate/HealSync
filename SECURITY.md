# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | ✅ Yes             |
| < 1.0   | ❌ No              |

## Reporting a Vulnerability

We take the security of HealSync seriously. If you discover a security vulnerability, please do NOT create a public issue. Instead, report it privately:

1. **Email**: Provide details to the project maintainers.
2. **Details**: Include a description of the vulnerability and steps to reproduce.
3. **Response**: We will acknowledge the report within 48 hours and provide updates on the fix.

## Hardening Recommendations
- **Rotate Secrets**: Always rotate `SECRET_KEY` and database passwords in production.
- **VPC Peering**: Ensure MySQL replication between regions is done via a secure VPC Peering OR transit gateway (as implemented in `terraform/`).
- **Encryption**: TLS should be enabled for all public routes (AWS ALB with Certificate Manager recommended).
