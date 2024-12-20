module RegistryTimeTraveler

using Pkg

export clone_registries_for_package

"""
```julia
generate_project_env(
    package_name::String,
    registries::Vector{Pkg.Registry.RegistryInstance}=Pkg.Registry.reachable_registries()
)
```

Trimmed down version of `Pkg.add` that only generates the Project.toml and Manifest.toml without actually downloading any packages.

This might go wrong, especially if there are extensions (for which `Pkg.add` needs to download).

Also this doesn't properly update an existing Manifest.toml (yet), so please activate an empty project first.

"""
function generate_project_env(
    package_name::String,
    registries::Vector{Pkg.Registry.RegistryInstance}=Pkg.Registry.reachable_registries()
)
    # add check that there's no existing Project and Manifest
    # dont support that yet...
    # but this might be nice for adding a package and it's test dependencies at release time

    pkg = PackageSpec(package_name)
    Pkg.API.handle_package_input!(pkg)
    pkgs = PackageSpec[pkg]
    ctx = Pkg.Operations.Context(registries = registries)

    # found inside Pkg.add, do we need all these?
    # Pkg.add(ctx, pkgs; preserve, platform, target, allow_autoprecomp)
    new_git = Set{Base.UUID}()
    Pkg.Types.project_deps_resolve!(ctx.env, pkgs)
    Pkg.Types.registry_resolve!(ctx.registries, pkgs)
    Pkg.Types.stdlib_resolve!(pkgs)
    Pkg.Types.ensure_resolved(ctx, ctx.env.manifest, pkgs, registry=true)
    #Pkg.API.update_source_if_set(ctx.env.project, pkg)

    # found inside Pkg.Operations.add
    # Pkg.Operations.add(ctx, pkgs, new_git; allow_autoprecomp, preserve, platform, target)
    preserve = Pkg.PRESERVE_NONE
    ctx.env.project.deps[pkg.name] = pkg.uuid
    man_pkgs, deps_map = Pkg.Operations.targeted_resolve(ctx.env, ctx.registries, [pkg], preserve, ctx.julia_version)
    Pkg.Operations.update_manifest!(ctx.env, man_pkgs, deps_map, ctx.julia_version)
    @info "generating Project.toml and Manifest.toml at $(dirname(ctx.env.project_file))"
    Pkg.Operations.write_env(ctx.env)
    return ctx.env
end

function get_depot_dir()
    return abspath(pwd())
end

function get_registries_dir(depot_dir::AbstractString=get_depot_dir())
    return abspath(depot_dir, "registries")
end

# clone only the history of all known registries
function clone_registry_histories(;
    registries_dir::AbstractString = get_registries_dir(),
    registries::Vector{Pkg.Registry.RegistryInstance} = Pkg.Registry.reachable_registries()
)
    if !isdir(registries_dir)
        mkdir(registries_dir)
    end
    for registry in registries
        registry_url = registry.repo
        registry_name = registry.name
        registry_path = abspath(registries_dir, registry_name)
        registry_path_history = registry_path * "_history"
        if !isdir(registry_path_history)
            @info "cloning registry history of $registry_name"
            run(`git clone --filter=blob:none --no-checkout --single-branch $registry_url $registry_path_history`)
        end
    end
end

function find_registry(registries::Vector{Pkg.Registry.RegistryInstance}, pkg_name::String)
    for reg in registries
        uuid_list = Pkg.Registry.uuids_from_name(reg, pkg_name)
        if !isempty(uuid_list)
            return reg
        end
    end
    error("could not find $pkg_name in registries")
end

function git_package_cmd(pkg::PackageSpec, new::String="version")
    # find commit date by commit message in registry where package is registered
    # this works for General and any registry using LocalRegistry
    c = `git rev-list -n 1 --first-parent origin --grep='New version: JSON v0.21.4'`
    pkg_version = "v" * string(pkg.version)
    new_version_msg = "--grep=New $new: $(pkg.name) $pkg_version"
    # hack to update Cmd... couldn't figure out how to interpolate inside single quoted Cmd
    # this will replace the last command '--grep=New version: JSON v0.21.4'
    c.exec[end] = new_version_msg
    return c
end

function find_package_release_date(
    pkg::PackageSpec;
    registries::Vector{Pkg.Registry.RegistryInstance} = Pkg.Registry.reachable_registries(),
    registries_dir = get_registries_dir()
)
    local commit_date
    current_pwd = pwd()

    package_registry = find_registry(registries, pkg.name)
    registry_name = package_registry.name
    registry_path = abspath(registries_dir, registry_name)
    registry_path_history = registry_path * "_history"

    try
        cd(registry_path_history)
        c = git_package_cmd(pkg, "version")
        release_commit = read(c, String) |> strip
        if isempty(release_commit)
            # try to see if it was registered as new package
            c = git_package_cmd(pkg, "package")
            release_commit = read(c, String) |> strip
        end
        if isempty(release_commit)
            error("could not find package $(pkg.name) $(pkg.version) in history of registry $registry_name")
        else
            commit_date = read(`git show -s --format=%ci $release_commit`, String) |> strip
        end
    catch e
        rethrow(e)
    finally
        cd(current_pwd)
    end

    return commit_date
end

function clone_registry_date(
    registry::Pkg.Registry.RegistryInstance,
    commit_date::AbstractString;
    registries_dir = get_registries_dir()
)
    current_pwd = pwd()
    registry_url = registry.repo
    registry_name = registry.name
    registry_path = abspath(registries_dir, registry_name)
    registry_path_history = registry_path * "_history"
    try
        cd(registry_path_history)
        # get commit by date (for any other registry)
        commit = read(`git rev-list -n 1 --first-parent --before=$commit_date origin`, String) |> strip
        if isempty(commit)
            error("found no commit in registry $registry_name before $commit_date")
        end
        # clone registry
        cd(current_pwd)
        if !isdir(registry_path)
            @info "cloning registry $registry_name head at depth 1"
            run(`git clone $registry_url --depth=1 $registry_path`)
        end
        cd(registry_path)
        @info "pulling registry $registry_name at commit $commit for date $commit_date"
        run(`git fetch --depth=1 origin $commit`)
        run(`git checkout $commit`)
    catch e
        rethrow(e)
    finally
        cd(current_pwd)
    end
    return nothing
end

function clone_registries_at_date(
    commit_date::AbstractString;
    registries::Vector{Pkg.Registry.RegistryInstance} = Pkg.Registry.reachable_registries(),
    registries_dir = get_registries_dir()
)
    for registry in registries
        clone_registry_date(registry, commit_date; registries_dir=registries_dir)
    end
end

function get_cloned_registries(;
    registries::Vector{Pkg.Registry.RegistryInstance} = Pkg.Registry.reachable_registries(),
    registries_dir = get_registries_dir()
)
    cloned_registries = Vector{Pkg.Registry.RegistryInstance}()
    for registry in registries
        registry_name = registry.name
        registry_path = abspath(registries_dir, registry_name)
        reg = Pkg.Registry.RegistryInstance(registry_path)
        push!(cloned_registries, reg)
    end
    return cloned_registries
end

"""
```julia
clone_registries_for_package(
    pkg::PackageSpec;
    registries_dir::AbstractString=get_registries_dir(),
    registries::Vector{Pkg.Registry.RegistryInstance} = Pkg.Registry.reachable_registries(),
)::Vector{Pkg.Registry.RegistryInstance}
```

For a specified package version, this will look at what date it was released in its corresponding registry.
Then it will clone all registries at that specified date.

You can then install packages as if you traveled back in time to the package release date.

Note: it will clone each registry twice, to try to reduce the download size.
* Once to get only the registry GIT history and find the right commit.
* And a second time to only clone the registry at that commit.
At the time of writing this still downloads about 220 MB of the General registry.

# Example

```julia
using Pkg, RegistryTimeTraveler

# go to some folder where registries will be installed
cd(pwd())

# choose your package and version
pkg = PackageSpec(name="JSON3", version="1.9.3")

cloned_registries = clone_registries_for_package(pkg)

# very important: dont let Pkg update the cloned registries!
Pkg.OFFLINE_MODE[] = true

Pkg.activate(".")
Pkg.add(pkg.name; registries=cloned_registries, preserve=Pkg.PRESERVE_NONE)

```
"""
function clone_registries_for_package(
    pkg::PackageSpec;
    registries_dir::AbstractString=get_registries_dir(),
    registries::Vector{Pkg.Registry.RegistryInstance} = Pkg.Registry.reachable_registries(),
)
    clone_registry_histories(; registries_dir, registries)
    release_date = find_package_release_date(pkg; registries_dir, registries)
    clone_registries_at_date(release_date; registries_dir, registries)
    new_registries = get_cloned_registries(;registries_dir, registries);
    return new_registries
end

function clone_registries_for_package(;name::String, version, kwargs...)
    pkg = PackageSpec(; name, version)
    return clone_registries_for_package(pkg; kwargs...)
end

end # module RegistryTimeTraveler
