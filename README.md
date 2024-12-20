# RegistryTimeTraveler.jl
Experimental package to clone Julia registries at a certain date, so you can install a package at its release date, using all of its dependencies versions at that release date.

This can be helpfull when no Manifest.toml was stored at the time of a package release.
So this will help if:
1. You want to reproduce the package version behavior at release time.
2. Have issues installing a package version with missing/incomplete compat entries.

Note: RegistryTimeTraveler.jl will clone each registry twice, to try to reduce the download size.
* Once to get only the registry GIT history and find the right commit.
* And a second time to only clone the registry at that commit.
At the time of writing this still downloads about 220 MB of the General registry.

Note2: this is not fully reproducible, because some Base packages are tied to your Julia version. So you might have to install the package with the Julia version used at the package release date. (But I haven't tested RegistryTimeTraveler at Julia versions less than 1.9).

## Example

Here's how to clone the registries (in your current folder `pwd()`) for a specific package version and then install that package with those registries.

```julia
using Pkg, RegistryTimeTraveler

# go to some folder where registries will be installed
cd(pwd())

# choose your package and version
pkg = PackageSpec(name="JSON3", version="1.9.3")

cloned_registries = clone_registries_for_package(pkg)

# very important: dont let Pkg update the cloned registries!
Pkg.OFFLINE_MODE[] = true

Pkg.activate("past_package")
Pkg.add(pkg.name; registries=cloned_registries, preserve=Pkg.PRESERVE_NONE)

```