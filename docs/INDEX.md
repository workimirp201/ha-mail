# Where to find what

| You want to… | Read |
|---|---|
| Understand the architecture and why each choice was made | `../README.md` (Phase 1) |
| Configure a deployment | `../env.example` (Phase 2) |
| Know what could go wrong and how it is prevented | `AUDIT.md` (Phase 5) |
| Publish DNS, including Linode reverse DNS | `DNS.md` (Phase 6) |
| Verify the cluster / run a failover drill | `TESTING.md` (Phase 7) |
| Add a domain, rotate a key, drain a node, restore | `OPERATIONS.md` |
| See every file the deploy writes | `../bin/render.sh --list` |
| Preview a change without applying it | `../deploy.sh --dry-run` |

Phase 3 (the admin portal) is implemented across
`../templates/postfixadmin/config.local.php.tpl`,
`../templates/nginx/site-admin.conf.tpl`, `../scripts/85-postfixadmin.sh` and
`AUDIT.md` §5.

Phase 4 (system implementation) is the whole of `../templates/` and
`../scripts/`.
