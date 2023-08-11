# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load(
    "@bazel_skylib//lib:paths.bzl",
    "paths",
)
load(
    "//go:def.bzl",
    "GoLibrary",
    "go_context",
)
load(
    "//go/private:go_toolchain.bzl",
    "GO_TOOLCHAIN",
)
load(
    "//go/private/rules:transition.bzl",
    "go_reset_target",
)

GoProtoCompiler = provider(
    doc = "Information and dependencies needed to generate Go code from protos",
    fields = {
        "compile": """A function with the signature:

    def compile(go, compiler, protos, imports, importpath)

where go is the go_context object, compiler is this GoProtoCompiler, protos
is a list of ProtoInfo providers for protos to compile, imports is a depset
of strings mapping proto import paths to Go import paths, and importpath is
the import path of the Go library being generated.

The function should declare output .go files and actions to generate them.
It should return a list of .go Files to be compiled by the Go compiler.
""",
        "deps": """List of targets providing GoLibrary, GoSource, and GoArchive.
These are added as implicit dependencies for any go_proto_library using this
compiler. Typically, these are Well Known Types and proto runtime libraries.""",
        "valid_archive": """A Boolean indicating whether the .go files produced
by this compiler are buildable on their own. Compilers that just add methods
to structs produced by other compilers will set this to False.""",
        "internal": "Opaque value containing data used by compile.",
    },
)

def go_proto_compile(go, compiler, protos, imports, importpath):
    """Invokes protoc to generate Go sources for a given set of protos

    Args:
        go: the go object, returned by go_context.
        compiler: a GoProtoCompiler provider.
        protos: list of ProtoInfo providers for protos to compile.
        imports: depset of strings mapping proto import paths to Go import paths.
        importpath: the import path of the Go library being generated.

    Returns:
        A list of .go Files generated by the compiler.
    """

    go_srcs = []
    outpath = None
    proto_paths = {}
    desc_sets = []
    for proto in protos:
        desc_sets.append(proto.transitive_descriptor_sets)
        for src in proto.check_deps_sources.to_list():
            path = proto_path(src, proto)
            if path in proto_paths:
                if proto_paths[path] != src:
                    fail("proto files {} and {} have the same import path, {}".format(
                        src.path,
                        proto_paths[path].path,
                        path,
                    ))
                continue
            proto_paths[path] = src

            if compiler.internal.suffixes:
                for suffix in compiler.internal.suffixes:
                    out = go.declare_file(
                        go,
                        path = importpath + "/" + src.basename[:-len(".proto")],
                        ext = suffix,
                    )
                    go_srcs.append(out)
            else:
                out = go.declare_file(
                    go,
                    path = importpath + "/" + src.basename[:-len(".proto")],
                    ext = compiler.internal.suffix,
                )
                go_srcs.append(out)

            if outpath == None:
                outpath = go_srcs[0].dirname[:-len(importpath)]

    transitive_descriptor_sets = depset(direct = [], transitive = desc_sets)

    args = go.actions.args()
    args.add("-protoc", compiler.internal.protoc)
    args.add("-importpath", importpath)
    args.add("-out_path", outpath)
    args.add("-plugin", compiler.internal.plugin)

    # TODO(jayconrod): can we just use go.env instead?
    args.add_all(compiler.internal.options, before_each = "-option")
    if compiler.internal.import_path_option:
        args.add_all([importpath], before_each = "-option", format_each = "import_path=%s")
    args.add_all(transitive_descriptor_sets, before_each = "-descriptor_set")
    args.add_all(go_srcs, before_each = "-expected")
    args.add_all(imports, before_each = "-import")
    args.add_all(proto_paths.keys())
    args.use_param_file("-param=%s")
    go.actions.run(
        inputs = depset(
            direct = [
                compiler.internal.go_protoc,
                compiler.internal.protoc,
                compiler.internal.plugin,
            ],
            transitive = [transitive_descriptor_sets],
        ),
        outputs = go_srcs,
        progress_message = "Generating into %s" % go_srcs[0].dirname,
        mnemonic = "GoProtocGen",
        executable = compiler.internal.go_protoc,
        arguments = [args],
        env = go.env,
        # We may need the shell environment (potentially augmented with --action_env)
        # to invoke protoc on Windows. If protoc was built with mingw, it probably needs
        # .dll files in non-default locations that must be in PATH. The target configuration
        # may not have a C compiler, so we have no idea what PATH should be.
        use_default_shell_env = "PATH" not in go.env,
    )
    return go_srcs

def proto_path(src, proto):
    """proto_path returns the string used to import the proto. This is the proto
    source path within its repository, adjusted by import_prefix and
    strip_import_prefix.

    Args:
        src: the proto source File.
        proto: the ProtoInfo provider.

    Returns:
        An import path string.
    """
    if proto.proto_source_root == ".":
        # true if proto sources were generated
        prefix = src.root.path + "/"
    elif proto.proto_source_root.startswith(src.root.path):
        # sometimes true when import paths are adjusted with import_prefix
        prefix = proto.proto_source_root + "/"
    else:
        # usually true when paths are not adjusted
        prefix = paths.join(src.root.path, proto.proto_source_root) + "/"
    if not src.path.startswith(prefix):
        # sometimes true when importing multiple adjusted protos
        return src.path
    return src.path[len(prefix):]

def _go_proto_compiler_impl(ctx):
    go = go_context(ctx)
    library = go.new_library(go)
    source = go.library_to_source(go, ctx.attr, library, ctx.coverage_instrumented())
    return [
        GoProtoCompiler(
            deps = ctx.attr.deps,
            compile = go_proto_compile,
            valid_archive = ctx.attr.valid_archive,
            internal = struct(
                options = ctx.attr.options,
                suffix = ctx.attr.suffix,
                suffixes = ctx.attr.suffixes,
                protoc = ctx.executable._protoc,
                go_protoc = ctx.executable._go_protoc,
                plugin = ctx.executable.plugin,
                import_path_option = ctx.attr.import_path_option,
            ),
        ),
        library,
        source,
    ]

_go_proto_compiler = rule(
    implementation = _go_proto_compiler_impl,
    attrs = {
        "deps": attr.label_list(providers = [GoLibrary]),
        "options": attr.string_list(),
        "suffix": attr.string(default = ".pb.go"),
        "suffixes": attr.string_list(),
        "valid_archive": attr.bool(default = True),
        "import_path_option": attr.bool(default = False),
        "plugin": attr.label(
            executable = True,
            cfg = "exec",
            mandatory = True,
        ),
        "_go_protoc": attr.label(
            executable = True,
            cfg = "exec",
            default = "//go/tools/builders:go-protoc",
        ),
        "_protoc": attr.label(
            executable = True,
            cfg = "exec",
            default = "//proto:protoc",
        ),
        "_go_context_data": attr.label(
            default = "//:go_context_data",
        ),
    },
    toolchains = [GO_TOOLCHAIN],
)

def go_proto_compiler(name, **kwargs):
    plugin = kwargs.pop("plugin", "@com_github_golang_protobuf//protoc-gen-go")
    reset_plugin_name = name + "_reset_plugin_"
    go_reset_target(
        name = reset_plugin_name,
        dep = plugin,
        visibility = ["//visibility:private"],
    )
    _go_proto_compiler(
        name = name,
        plugin = reset_plugin_name,
        **kwargs
    )
