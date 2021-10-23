# MPTCP Upstream Build Export Action

This action is specific to MPTCP Upstream repo to validate the `export` branch
in [mptcp_net-next](https://github.com/multipath-tcp/mptcp_net-next) repo.

The idea here is to validate the updated tree by building the kernel.

## Inputs

### `each_commit`

Set it to `true` to validate the compilation of each commit. Default: `true`.

### `ccache_maxsize`

Set the maximum size for CCache in `${{ github.workspace }}/.ccache` dir.
Default: `5G`.

### `defconfig`

Set the defconfig to pick: `x86_64` or `i386`. Default: `x86_64`.

### `ipv6`

Compile with or without IPv6 support. Default: `with_ipv6`.

### `mptcp`

Compile with or without MPTCP support. Default: `with_mptcp`.

### `checkpatch`

Set it to `true` to run checkpatch exclusively. Default: `false`.

## Example usage

```yaml
uses: multipath-tcp/mptcp-upstream-build-export-action@main
with:
  each_commit: true
  ccache_maxsize: 5G
  defconfig: x86_64
  ipv6: with_ipv6
  mptcp: with_mptcp
  checkpatch: false
```
