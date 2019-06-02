"""Rules for importing Nixpkgs packages."""

load("@bazel_tools//tools/cpp:cc_configure.bzl", "cc_autoconf_impl")
load("@bazel_tools//tools/cpp:lib_cc_configure.bzl", "get_cpu_value")

def _nixpkgs_git_repository_impl(repository_ctx):
    repository_ctx.file("BUILD")

    # Make "@nixpkgs" (syntactic sugar for "@nixpkgs//:nixpkgs") a valid
    # label for default.nix.
    repository_ctx.symlink("default.nix", repository_ctx.name)

    repository_ctx.download_and_extract(
        url = "%s/archive/%s.tar.gz" % (repository_ctx.attr.remote, repository_ctx.attr.revision),
        stripPrefix = "nixpkgs-" + repository_ctx.attr.revision,
        sha256 = repository_ctx.attr.sha256,
    )

nixpkgs_git_repository = repository_rule(
    implementation = _nixpkgs_git_repository_impl,
    attrs = {
        "revision": attr.string(mandatory = True),
        "remote": attr.string(default = "https://github.com/NixOS/nixpkgs"),
        "sha256": attr.string(),
    },
)

def _nixpkgs_local_repository_impl(repository_ctx):
    repository_ctx.file("BUILD")
    if not bool(repository_ctx.attr.nix_file) != \
       bool(repository_ctx.attr.nix_file_content):
        fail("Specify one of 'nix_file' or 'nix_file_content' (but not both).")
    if repository_ctx.attr.nix_file_content:
        repository_ctx.file(
            path = "default.nix",
            content = repository_ctx.attr.nix_file_content,
            executable = False,
        )
        target = repository_ctx.path("default.nix")
    else:
        target = repository_ctx.path(repository_ctx.attr.nix_file)
        repository_ctx.symlink(target, target.basename)

    # Make "@nixpkgs" (syntactic sugar for "@nixpkgs//:nixpkgs") a valid
    # label for the target Nix file.
    repository_ctx.symlink(target.basename, repository_ctx.name)

    _symlink_nix_file_deps(repository_ctx, repository_ctx.attr.nix_file_deps)

nixpkgs_local_repository = repository_rule(
    implementation = _nixpkgs_local_repository_impl,
    attrs = {
        "nix_file": attr.label(allow_single_file = [".nix"]),
        "nix_file_deps": attr.label_list(),
        "nix_file_content": attr.string(),
    },
)

def _is_supported_platform(repository_ctx):
    return repository_ctx.which("nix-build") != None

def _nixpkgs_package_impl(repository_ctx):
    repository = repository_ctx.attr.repository
    repositories = repository_ctx.attr.repositories

    # Is nix supported on this platform?
    not_supported = not _is_supported_platform(repository_ctx)
    # Should we fail if Nix is not supported?
    fail_not_supported = repository_ctx.attr.fail_not_supported

    if repository and repositories or not repository and not repositories:
        fail("Specify one of 'repository' or 'repositories' (but not both).")
    elif repository:
        repositories = {repository_ctx.attr.repository: "nixpkgs"}

    if repository_ctx.attr.build_file and repository_ctx.attr.build_file_content:
        fail("Specify one of 'build_file' or 'build_file_content', but not both.")
    elif repository_ctx.attr.build_file:
        repository_ctx.symlink(repository_ctx.attr.build_file, "BUILD")
    elif repository_ctx.attr.build_file_content:
        repository_ctx.file("BUILD", content = repository_ctx.attr.build_file_content)
    else:
        repository_ctx.template("BUILD", Label("@io_tweag_rules_nixpkgs//nixpkgs:BUILD.pkg"))

    strFailureImplicitNixpkgs = (
        "One of 'repositories', 'nix_file' or 'nix_file_content' must be provided. " +
        "The NIX_PATH environment variable is not inherited."
    )

    expr_args = []
    if repository_ctx.attr.nix_file and repository_ctx.attr.nix_file_content:
        fail("Specify one of 'nix_file' or 'nix_file_content', but not both.")
    elif repository_ctx.attr.nix_file:
        repository_ctx.symlink(repository_ctx.attr.nix_file, "default.nix")
    elif repository_ctx.attr.nix_file_content:
        expr_args = ["-E", repository_ctx.attr.nix_file_content]
    elif not repositories:
        fail(strFailureImplicitNixpkgs)
    else:
        expr_args = ["-E", "import <nixpkgs> { config = {}; }"]

    _symlink_nix_file_deps(repository_ctx, repository_ctx.attr.nix_file_deps)

    expr_args.extend([
        "-A",
        repository_ctx.attr.attribute_path if repository_ctx.attr.nix_file or repository_ctx.attr.nix_file_content else repository_ctx.attr.attribute_path or repository_ctx.attr.name,
        # Creating an out link prevents nix from garbage collecting the store path.
        # nixpkgs uses `nix-support/` for such house-keeping files, so we mirror them
        # and use `bazel-support/`, under the assumption that no nix package has
        # a file named `bazel-support` in its root.
        # A `bazel clean` deletes the symlink and thus nix is free to garbage collect
        # the store path.
        "--out-link",
        "bazel-support/nix-out-link",
    ])

    expr_args.extend(repository_ctx.attr.nixopts)

    # If repositories is not set, leave empty so nix will fail
    # unless a pinned nixpkgs is set in the `nix_file` attribute.
    nix_path = ""
    if repositories:
        nix_path = ":".join(
            [
                (path_name + "=" + str(repository_ctx.path(target)))
                for (target, path_name) in repositories.items()
            ],
        )
    elif not (repository_ctx.attr.nix_file or repository_ctx.attr.nix_file_content):
        fail(strFailureImplicitNixpkgs)


    if not_supported and fail_not_supported:
        fail("Platform is not supported (see 'fail_not_supported')")
    elif not_supported:
        return
    else:
        nix_build_path = _executable_path(
            repository_ctx,
            "nix-build",
            extra_msg = "See: https://nixos.org/nix/",
        )

        # -vv will generate extra verbose output, used for dependencies detection
        nix_build = [nix_build_path] + expr_args + ["-vv"]

        # Large enough integer that Bazel can still parse. We don't have
        # access to MAX_INT and 0 is not a valid timeout so this is as good
        # as we can do.
        timeout = 1073741824
        exec_result = _execute_or_fail(
            repository_ctx,
            nix_build,
            failure_message = "Cannot build Nix attribute '{}'.".format(
                repository_ctx.attr.attribute_path,
            ),
            timeout = timeout,
            environment = dict(NIX_PATH = nix_path),
        )
        output_path = exec_result.stdout.splitlines()[-1]

        # HERMETIC heuristic
        # The following pieces of code tries to detect the
        # dependencies needed by nix during the build of the package
        # and will fail the bazel process if any implicit dependency
        # is not correctly listed by the user

        # A more robust solution may be a sandbox,
        # see https://github.com/bazelbuild/bazel/issues/7764

        # Contains the dependencies detected during nix evaluation
        # Nix list them as realpath (with symbolic link resolved)
        deps = []
        for line in exec_result.stderr.splitlines():
            line = line.split(sep=' ')

            # Interesting lines contains at least 3 words
            if len(line) < 3:
                continue

            # Heuristic: a dependency is something which looks like:
            # evaluating file FILE
            # copied source FILE
            if (line[0], line[1]) in [("evaluating", "file"), ("copied", "source")]:
                # We ignore some files:
                # - Anything in /nix/store, they are not explicit dependencies are are supposed to be immutable
                # - Anything from .cache/bazel, only case I encountered was a local nixpkgs clone handled by bazel
                if (
                   not line[2].startswith("'/nix/store")
                   and ".cache/bazel" not in line[2]
                ):
                    filename = line[2][1:-1] # trimming quotes

                    # This filename can be either a file or a directory
                    # this find command will list all the sub files of a potential directory
                    find_result = _execute_or_fail(
                        repository_ctx,
                        [_executable_path(repository_ctx, "find"), filename, "-type", "f", "-print0"],
                    )

                    # filenames are separated by \0 to allow filenames with newlines
                    for filename in find_result.stdout.rstrip("\0").split("\0"):
                        deps.append(filename)

        # declared deps contains all the implicit dependencies declared by the user
        # starting by all the files in `nix_file_deps`
        # realpath is used to match files listed by nix
        # Note: we use a dict with all value to None to represent a set
        declared_deps = {str(repository_ctx.path(f).realpath):None for f in repository_ctx.attr.nix_file_deps}

        # extend declared deps with the list of all repositories files
        if repository_ctx.attr.nix_file:
            declared_deps[str(repository_ctx.path(repository_ctx.attr.nix_file))] = None
        for rep in repositories.keys():
            declared_deps[str(repository_ctx.path(rep).realpath)] = None

        # Set substraction deps - declared_deps must be empty
        # Note: we do not fail if some declared deps are not
        # necessary, better safe than sorry, this won't affect
        # reproducibility, and we are not sure that the current
        # heuristic can find all the indirect dependencies

        deps_minus_declared_deps = dict()
        for dep in deps:
            if dep not in declared_deps:
                # Set behavior here
                deps_minus_declared_deps[dep] = None

        if deps_minus_declared_deps:
            fail("""

Non hermetic configuration for repository {repo_name}.

The following dependencies are not declared in *nixpkgs_package* attributes.

You need to update the repository rule *{repo_name}* and set/extend *nix_file_deps* with the following dependencies (adapted to your workspace):

nix_file_deps = [
    "{deps_listing}",
]

Note: if it points to the nixpkgs global configuration file, such as ~/.config/nixpkgs/config.nix. You must force nixpkgs to not use the local configuration, by providing a `config` argument to your nixpkgs import, such as:

import (nixpkgs_path) {{ config = {{}}; }};
""".format(repo_name = repository_ctx.name,
           deps_listing = '",\n    "'.join(deps_minus_declared_deps.keys())))
                
        # Build a forest of symlinks (like new_local_package() does) to the
        # Nix store.
        for target in _find_children(repository_ctx, output_path):
            basename = target.rpartition("/")[-1]
            repository_ctx.symlink(target, basename)

_nixpkgs_package = repository_rule(
    implementation = _nixpkgs_package_impl,
    attrs = {
        "attribute_path": attr.string(),
        "nix_file": attr.label(allow_single_file = [".nix"]),
        "nix_file_deps": attr.label_list(),
        "nix_file_content": attr.string(),
        "repositories": attr.label_keyed_string_dict(),
        "repository": attr.label(),
        "build_file": attr.label(),
        "build_file_content": attr.string(),
        "nixopts": attr.string_list(),
        "fail_not_supported": attr.bool(default = True, doc = """
            If set to True (default) this rule will fail on platforms which do not support Nix (e.g. Windows). If set to False calling this rule will succeed but no output will be generated.
                                        """),
    },
)

def nixpkgs_package(*args, **kwargs):
    # Because of https://github.com/bazelbuild/bazel/issues/5356 we can't
    # directly pass a dict from strings to labels to the rule (which we'd like
    # for the `repositories` arguments), but we can pass a dict from labels to
    # strings. So we swap the keys and the values (assuming they all are
    # distinct).
    if "repositories" in kwargs:
        inversed_repositories = {value: key for (key, value) in kwargs["repositories"].items()}
        kwargs.pop("repositories")
        _nixpkgs_package(
            repositories = inversed_repositories,
            *args,
            **kwargs
        )
    else:
        _nixpkgs_package(*args, **kwargs)

def _readlink(repository_ctx, path):
    return repository_ctx.path(path).realpath

def nixpkgs_cc_autoconf_impl(repository_ctx):
    cpu_value = get_cpu_value(repository_ctx)
    if not _is_supported_platform(repository_ctx):
        cc_autoconf_impl(repository_ctx)
        return

    # Calling repository_ctx.path() on anything but a regular file
    # fails. So the roundabout way to do the same thing is to find
    # a regular file we know is in the workspace (i.e. the WORKSPACE
    # file itself) and then use dirname to get the path of the workspace
    # root.
    workspace_file_path = repository_ctx.path(
        Label("@nixpkgs_cc_toolchain//:WORKSPACE"),
    )
    workspace_root = _execute_or_fail(
        repository_ctx,
        ["dirname", workspace_file_path],
    ).stdout.rstrip()

    # Make a list of all available tools in the Nix derivation. Override
    # the Bazel autoconfiguration with the tools we found.
    bin_contents = _find_children(repository_ctx, workspace_root + "/bin")
    overriden_tools = {
        tool: _readlink(repository_ctx, entry)
        for entry in bin_contents
        for tool in [entry.rpartition("/")[-1]]  # Compute basename
    }
    cc_autoconf_impl(repository_ctx, overriden_tools = overriden_tools)

nixpkgs_cc_autoconf = repository_rule(
    implementation = nixpkgs_cc_autoconf_impl,
    # Copied from
    # https://github.com/bazelbuild/bazel/blob/master/tools/cpp/cc_configure.bzl.
    # Keep in sync.
    environ = [
        "ABI_LIBC_VERSION",
        "ABI_VERSION",
        "BAZEL_COMPILER",
        "BAZEL_HOST_SYSTEM",
        "BAZEL_LINKOPTS",
        "BAZEL_PYTHON",
        "BAZEL_SH",
        "BAZEL_TARGET_CPU",
        "BAZEL_TARGET_LIBC",
        "BAZEL_TARGET_SYSTEM",
        "BAZEL_USE_CPP_ONLY_TOOLCHAIN",
        "BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN",
        "BAZEL_USE_LLVM_NATIVE_COVERAGE",
        "BAZEL_VC",
        "BAZEL_VS",
        "BAZEL_LLVM",
        "USE_CLANG_CL",
        "CC",
        "CC_CONFIGURE_DEBUG",
        "CC_TOOLCHAIN_NAME",
        "CPLUS_INCLUDE_PATH",
        "GCOV",
        "HOMEBREW_RUBY_PATH",
        "SYSTEMROOT",
        "VS90COMNTOOLS",
        "VS100COMNTOOLS",
        "VS110COMNTOOLS",
        "VS120COMNTOOLS",
        "VS140COMNTOOLS",
    ],
)

def nixpkgs_cc_configure(
        repository = None,
        repositories = {},
        nix_file = None,
        nix_file_deps = None,
        nix_file_content = None,
        nixopts = []):
    """Use a CC toolchain from Nixpkgs. No-op if not a nix-based platform.

    By default, Bazel auto-configures a CC toolchain from commands (e.g.
    `gcc`) available in the environment. To make builds more hermetic, use
    this rule to specific explicitly which commands the toolchain should
    use.
    """
    if not nix_file and not nix_file_content:
        nix_file_content = """
          with import <nixpkgs> { config = {}; }; buildEnv {
            name = "bazel-cc-toolchain";
            paths = [ stdenv.cc binutils ];
          }
        """
    nixpkgs_package(
        name = "nixpkgs_cc_toolchain",
        repository = repository,
        repositories = repositories,
        nix_file = nix_file,
        nix_file_deps = nix_file_deps,
        nix_file_content = nix_file_content,
        build_file_content = """exports_files(glob(["bin/*"]))""",
        nixopts = nixopts,
    )

    # Following lines should match
    # https://github.com/bazelbuild/bazel/blob/master/tools/cpp/cc_configure.bzl#L93.
    nixpkgs_cc_autoconf(name = "local_config_cc")
    native.bind(name = "cc_toolchain", actual = "@local_config_cc//:toolchain")
    native.register_toolchains("@local_config_cc//:all")

def _execute_or_fail(repository_ctx, arguments, failure_message = "", *args, **kwargs):
    """Call repository_ctx.execute() and fail if non-zero return code."""
    result = repository_ctx.execute(arguments, *args, **kwargs)
    if result.return_code:
        outputs = dict(
            failure_message = failure_message,
            arguments = arguments,
            return_code = result.return_code,
            stderr = result.stderr,
        )
        fail("""
{failure_message}
Command: {arguments}
Return code: {return_code}
Error output:
{stderr}
""".format(**outputs))
    return result

def _find_children(repository_ctx, target_dir):
    find_args = [
        _executable_path(repository_ctx, "find"),
        "-L",
        target_dir,
        "-maxdepth",
        "1",
        # otherwise the directory is printed as well
        "-mindepth",
        "1",
        # filenames can contain \n
        "-print0",
    ]
    exec_result = _execute_or_fail(repository_ctx, find_args)
    return exec_result.stdout.rstrip("\0").split("\0")

def _executable_path(repository_ctx, exe_name, extra_msg = ""):
    """Try to find the executable, fail with an error."""
    path = repository_ctx.which(exe_name)
    if path == None:
        fail("Could not find the `{}` executable in PATH.{}\n"
            .format(exe_name, " " + extra_msg if extra_msg else ""))
    return path

def _symlink_nix_file_deps(repository_ctx, deps):
    """Introduce an artificial dependency with a bogus name on each input."""
    for dep in deps:
        components = [c for c in [dep.workspace_root, dep.package, dep.name] if c]
        link = "/".join(components).replace("_", "_U").replace("/", "_S")
        repository_ctx.symlink(dep, link)
