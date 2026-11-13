# Apple Metal Shader Converter 4.0 beta 3 (iOS)

From Apple's installer (`Metal Shader Converter 4.0 beta 3.pkg`, sha256 449833211e4ef0d46bfaa94848e801acff49e226d3c348bba0673f13716be622).

- `lib_iOS/libmetalirconverter.dylib` (sha256 3040a91ea3559dbcf966f3dfbb21614275e217b4f63fcf8c67de23b17d3f5518): Apple proprietary, shipped inside the app under Apple's Metal Shader Converter agreement (as BCD does with beta 2, see BCD's app/Madeira/d3d12/NOTICE.txt). Used only to convert DXIL shaders to Metal on Apple devices.
- `include/`: the public headers (Apache-2.0, unchanged).

`tools/windows/build_runtime.sh` copies both into BCD's tree before BCD's build and re-pins BCD's hash check (BCD v0.1.653 pins beta 2 and its public repo lacks the dylib). Beta 3 vs beta 2 headers: only `IRCompatibilityFlagEnsureTGMemoryCoherency` added and the patch version.
