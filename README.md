# MPTCP Upstream TopGit Action

This action is specific to MPTCP Upstream repo to manage the TopGit tree in
[mptcp_net-next](https://github.com/multipath-tcp/mptcp_net-next) repo.

The idea here is to periodically sync the tree with upstream (net-next repo),
validate the updated tree by building the kernel and if everything is OK,
publish the new tree to the repo.

## Inputs

### `force-sync`

Set it to 1 to force a sync even if net-next is already up to date. Default:
`0`.

### `not-base`

Set it to 1 to force a sync without updating the base from upstream. Default:
`0`.

### `validate-each-topic`

Set it to 1 to validate the compilation of each topic. Default: `1`.

### `ccache-maxsize`

Set the maximum size for CCache in `/ccache` dir. Default: `2G`.

## Example usage

```yaml
uses: multipath-tcp/mptcp-upstream-topgit-action@main
with:
  validate-each-topic: '1'
```
