# RLS Vehicle Scanner

Standalone BeamNG phone app for RLS Career Overhaul. It presents real BeamNG/RLS vehicle diagnostics and maintenance data in plausible scan-tool language. Do not invent OBD fault codes or expose raw simulation/debug coefficients; hide unsupported values.

## References

`docs/` contains unpacked third-party mods for reference only: the RLS Career Overhaul and a working standalone RLS phone app. Treat everything under `docs/` as strictly read-only, never copy or ship its files, and keep it ignored by Git.

## BeamNG MCP

Codex MCP server name: `beamng`

WSL URL: `http://172.17.144.1:29293/mcp`

Windows proxy: `172.17.144.1:29293` → BeamNG `127.0.0.1:29292`. BeamNG must be running, and Codex must start a fresh session after MCP configuration changes. The WSL adapter IP can change after a networking restart.
