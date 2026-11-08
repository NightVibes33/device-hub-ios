# idevice dependency

Device Hub builds on [idevice](https://github.com/jkcoxson/idevice), pinned to
revision `a64b8867815b3da17b5c927531bdba877e8456ef` (version `0.1.65`).
The app needs protocol and security changes that are not yet available in that
upstream revision, so setup applies the reviewed patch in
`patches/idevice-device-hub.patch`.

The patch also backports the `cryptexd` service (DDI cryptex lookup and
install) from upstream commit `730589495cf8aa22d3c7e6391567393b6cb7767d`,
so the app recognizes the developer image that iOS 26.4 and later install as a
cryptex. The backported `cryptexd` feature additionally enables `tss`, which
its install path needs.

`Vendor/idevice` is generated and ignored rather than committed or managed as a
submodule. `BuildSupport/bootstrap_idevice.py` checks out the immutable upstream
revision, verifies the patch and resulting source tree, and fails closed if an
existing checkout contains local changes.

The upstream project is MIT licensed. Its unmodified license notice is retained
at `Licenses/idevice-MIT.txt` and is also materialized as
`Vendor/idevice/LICENSE.txt` during setup.

Updating idevice requires reviewing the upstream diff, rebasing the patch,
updating the revision and integrity digests in
`BuildSupport/bootstrap_idevice.py` and `Rust/DeviceHubFFI/Cargo.toml`,
regenerating `Rust/Cargo.lock`, and running the complete Rust test suite.
