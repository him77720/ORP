%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 2008-2025. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

%%

-module(pubkey_os_cacerts).
-moduledoc false.

-include("public_key.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").
-export([load/0, load/1, get/0, clear/0, format_error/2]).

-on_load(on_load/0).
-nifs([os_cacerts/0]).

%% API

%% Return cacerts
-spec get() -> [public_key:combined_cert()].
get() ->
    case persistent_term:get(?MODULE, not_loaded) of
        not_loaded ->
            _ = application:load(public_key),

            Result =
                case application:get_env(public_key, cacerts_path) of
                    {ok, EnvVar} -> load([EnvVar]);
                    undefined -> load()
                end,

            case Result of
                ok ->
                    persistent_term:get(?MODULE);
                {error, Reason} ->
                    erlang:error(
                        {failed_load_cacerts, conv_error_reason(Reason)},
                        none,
                        [{error_info, #{cause => Reason, module => ?MODULE}}]
                    )
            end;
        CaCerts ->
            CaCerts
    end.

%% (Re)Load default os cacerts and cache result.
-spec load() ->  ok | {error, Reason::term()}.
load() ->
    DefError = {error, no_cacerts_found},
    case os:type() of
        {unix, linux} ->
            load(linux_paths(), DefError);
        {unix, openbsd} ->
            load(bsd_paths(), DefError);
        {unix, freebsd} ->
            load(bsd_paths(), DefError);
        {unix, dragonfly} ->
            load(bsd_paths(), DefError);
        {unix, netbsd} ->
            load(bsd_paths(), DefError);
        {unix, sunos} ->
            load(sunos_paths(), DefError);
        {win32, _} ->
            load_win32();
	{unix, darwin} ->
            load_darwin();
        Os ->
            {error, {enotsup, Os}}
    end.

%% (Re)Load cacerts from file and cache result.
%% The file-paths will be tried in order.
%% Can be used when load/0 doesn't work for an unsupported os type.
-spec load([file:filename_all()]) -> ok | {error, Reason::term()}.
load(Paths) ->
    load(Paths, {error, enoent}).

%% cleanup persistent_key
-spec clear() -> boolean().
clear() ->
    persistent_term:erase(?MODULE).

load([Path|Paths], Error) ->
    case dir_or_file(Path) of
        enoent ->
            load(Paths, Error);
        directory ->
            case load_from_files(Path) of
                ok -> ok;
                Err -> load(Paths, Err)
            end;
        file ->
            case load_from_file(Path) of
                ok -> ok;
                Err -> load(Paths, Err)
            end
    end;
load([], Error) ->
    Error.

dir_or_file(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = directory}} ->
            directory;
        {ok, #file_info{type = regular}} ->
            file;
        {ok, #file_info{}} ->  %% Link
            case filelib:is_dir(Path) of
                true -> directory;
                false -> file
            end;
        {error, _} -> enoent
    end.

%% Implementation
load_from_file(Path) when is_list(Path); is_binary(Path) ->
    try
        {ok, Binary} = file:read_file(Path),
        ok = decode_result(Binary)
    catch _:_Reason ->
            {error, enoent}
    end.

decode_result(Binary) ->
    try
        MakeCert = fun({'Certificate', Der, not_encrypted}, Acc) ->
                           try
                               Decoded = public_key:pkix_decode_cert(Der, otp),
                               [#cert{der=Der, otp=Decoded}|Acc]
                           catch _:_ ->
                                   Acc
                           end;
                      (Wrong, Acc) ->
                           ?LOG_WARNING("PUBKEY cacerts load: Ignored content of type: ~w",
                                        [element(1, Wrong)]),
                           Acc
                   end,
        Certs = lists:foldl(MakeCert, [], pubkey_pem:decode(Binary)),
        store(Certs)
    catch _:Reason ->
            {error, Reason}
    end.

load_from_files(Path) ->
    MakeCert = fun(FileName, Acc) ->
                       try
                           {ok, Bin} = file:read_file(FileName),
                           [#cert{der=Der, otp=public_key:pkix_decode_cert(Der, otp)}
                            || {'Certificate', Der, not_encrypted} <- pubkey_pem:decode(Bin)]
                               ++ Acc
                       catch _:_ ->
                               Acc
                       end
               end,
    Certs = filelib:fold_files(Path, ".*\.pem", false, MakeCert, []),
    store(Certs).

load_win32() ->
    Dec = fun({_Enc, Der}, Acc) ->
                  try
                      Decoded = public_key:pkix_decode_cert(Der, otp),
                      [#cert{der=Der, otp=Decoded}|Acc]
                  catch _:_ ->
                          Acc
                  end
          end,
    store(lists:foldl(Dec, [], os_cacerts())).

load_darwin() ->
    SystemRootsKeyChainFile = "/System/Library/Keychains/SystemRootCertificates.keychain",
    case get_darwin_certs(SystemRootsKeyChainFile) of
         {ok, Bin1} ->
            SystemKeyChainFile = "/Library/Keychains/System.keychain",
            case get_darwin_certs(SystemKeyChainFile) of
                 {ok, Bin2} ->
                    decode_result(<<Bin1/binary, Bin2/binary>>);
                  Err ->
                    ?LOG_WARNING(
                        "Unable to load additional OS certificates from System.keychain : ~p~n", [Err]),
                    decode_result(Bin1)
             end;
          Err ->
            Err
    end.

get_darwin_certs(KeyChainFile) ->
    %% Could/should probably be re-written to use Keychain Access API
    Args = ["export", "-t",  "certs", "-f", "pemseq", "-k", KeyChainFile],
    try run_cmd("/usr/bin/security", Args) of
        {ok, _} = Res -> Res;
        Err -> Err
    catch error:Reason ->
            {error, {eopnotsupp, Reason}}
    end.

store([]) ->
    {error, no_cacerts_found};
store(CaCerts) ->
    persistent_term:put(?MODULE, CaCerts).

linux_paths() ->
    ["/etc/ssl/certs/ca-certificates.crt",                %% Debian, Ubuntu, Gentoo
     "/etc/pki/tls/certs/ca-bundle.crt",                  %% Fedora, RHEL 6, Amazon Linux
     "/etc/ssl/ca-bundle.pem",                            %% OpenSUSE
     "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", %% CentOS, RHEL 7
     "/etc/ssl/cert.pem"                                  %% Alpine Linux
    ].

bsd_paths() ->
    ["/etc/ssl/cert.pem",
     "/etc/openssl/certs/cacert.pem",   %% netbsd (if installed)
     "/etc/openssl/certs/ca-certificates.crt",
     "/usr/local/share/certs/ca-root-nss.crt"
    ].

sunos_paths() ->
    ["/etc/certs/CA/", %% Oracle Solaris, some older illumos distros
     "/etc/ssl/cacert.pem" %% OmniOS
    ].

run_cmd(Cmd, Args) ->
    Opts = [binary, exit_status, stderr_to_stdout],
    Port = open_port({spawn_executable, Cmd}, [{args, Args}|Opts]),
    unlink(Port),
    cmd_data(Port, <<>>).

cmd_data(Port, Acc) ->
    receive
        {Port, {data, Bin}} ->
            cmd_data(Port, <<Acc/binary, Bin/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, Status}} ->
            {error, {eopnotsupp, Status, Acc}}
    end.

%%%
%%% NIF placeholders
%%%

-spec os_cacerts() -> [{Encoding::atom(), Cert::binary()}].

os_cacerts() ->
    erlang:nif_error(nif_not_loaded).

on_load() ->
    case os:type() of
        {win32, _} -> load_nif();
        _ -> ok
    end.

load_nif() ->
    PrivDir = code:priv_dir(public_key),
    LibName = "public_key",
    Lib = filename:join([PrivDir, "lib", LibName]),
    case erlang:load_nif(Lib, 0) of
        ok -> ok;
        {error, {load_failed, _}}=Error1 ->
            Arch = case os:type() of
                       {win32, _} -> win32;
                       _ ->
                           erlang:system_info(system_architecture)
                   end,
            ArchLibDir = filename:join([PrivDir, "lib", Arch]),
            Candidate =
                filelib:wildcard(
                  filename:join([ArchLibDir,LibName ++ "*" ]),
                  erl_prim_loader),
            case Candidate of
                [] -> Error1;
                _ ->
                    ArchLib = filename:join([ArchLibDir, LibName]),
                    erlang:load_nif(ArchLib, 0)
            end;
        Error1 -> Error1
    end.

%%%
%%% Error Handling
%%%

conv_error_reason(enoent) -> enoent;
conv_error_reason({enotsup, _OS}) -> enotsup;
conv_error_reason({eopnotsupp, _Reason}) -> eopnotsupp;
conv_error_reason({eopnotsupp, _Status, _Acc}) -> eopnotsupp.

-spec format_error(Reason, StackTrace) -> ErrorMap when
      Reason :: term(),
      StackTrace :: erlang:stacktrace(),
      ErrorMap :: #{pos_integer() => unicode:chardata(),
                    general => unicode:chardata(),
                    reason => unicode:chardata()}.

format_error(Reason, [{_M, _F, _As, Info} | _]) ->
    ErrorInfoMap = proplists:get_value(error_info, Info, #{}),
    Cause = maps:get(cause, ErrorInfoMap, none),
    Message = case Cause of
        enoent ->
            "operating system CA bundle could not be located";
        {enotsup, OS} ->
            io_lib:format("operating system ~p is not supported", [OS]);
        {eopnotsupp, SubReason} ->
            io_lib:format("operation failed because of ~p", [SubReason]);
        {eopnotsupp, Status, _Acc} ->
            io_lib:format("operation failed with status ~B", [Status])
    end,
    #{general => io_lib:format("Failed to load cacerts: ~s", [Message]),
      reason => io_lib:format("~p: ~p", [?MODULE, Reason])}.
