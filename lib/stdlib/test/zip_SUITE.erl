%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 2006-2025. All Rights Reserved.
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
-module(zip_SUITE).

-export([all/0, suite/0,groups/0,init_per_suite/1, end_per_suite/1, 
	 init_per_group/2,end_per_group/2,
         init_per_testcase/2, end_per_testcase/2]).

-export([borderline/1, atomic/1,
         bad_zip/1, unzip_from_binary/1, unzip_to_binary/1,
         zip_to_binary/1, sanitize_filenames/1,
         unzip_options/1, zip_options/1, list_dir_options/1, aliases/1,
         zip_api/1, open_leak/1, unzip_jar/1,
	 unzip_traversal_exploit/1,
         compress_control/1,
	 foldl/1,fd_leak/1,unicode/1,test_zip_dir/1,
         explicit_file_info/1, mode/1,
         zip64_central_headers/0, unzip64_central_headers/0,
         zip64_central_headers/1, unzip64_central_headers/1,
         zip64_central_directory/1,
         basic_timestamp/1, extended_timestamp/1, capped_timestamp/1,
         uid_gid/1]).

-export([zip/5, unzip/3]).

-import(proplists,[get_value/2, get_value/3]).

-include_lib("common_test/include/ct.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("stdlib/include/zip.hrl").
-include_lib("stdlib/include/assert.hrl").

suite() -> [{ct_hooks,[ts_install_cth]}].

all() -> 
    [borderline, atomic, bad_zip, unzip_from_binary,
     unzip_to_binary, zip_to_binary, unzip_options,
     zip_options, list_dir_options, aliases,
     zip_api, open_leak, unzip_jar, compress_control, foldl,
     unzip_traversal_exploit, fd_leak, unicode, test_zip_dir,
     explicit_file_info, {group, zip_group}, {group, zip64_group}].

groups() -> 
    zip_groups().

%% zip   - Use zip unix tools
%% ezip  - Use erlang zip on disk
%% emzip - Use erlang zip in memory
-define(ZIP_MODES,[zip, ezip, emzip]).
%% -define(ZIP_MODES,[emzip]).
-define(UNZIP_MODES,[unzip, unezip, unemzip]).
%% How much memory the zip/unzip 64 testcases that zip/unzip from/to are expected to use
-define(EMZIP64_MEM_USAGE, (8 * (1 bsl 30))).

zip_groups() ->

    ZipGroup=
        [{zip_group,[],[{group,ZipMode} || ZipMode <- ?ZIP_MODES]}] ++
        [{ZipMode, [], [{group,UnZipMode} || UnZipMode <- ?UNZIP_MODES]}
         || ZipMode <- ?ZIP_MODES] ++
        [{G, [parallel], zip_testcases()} || G <- ?UNZIP_MODES],

    Zip64Group = [{zip64_group,[],[{group,z64(ZipMode)} || ZipMode <- ?ZIP_MODES]}] ++
        [{z64(ZipMode), [sequence], [zip64_central_headers]++
              [{group,z64(UnZipMode)} || UnZipMode <- ?UNZIP_MODES]}
         || ZipMode <- ?ZIP_MODES] ++
        [{z64(G), [], zip64_testcases()} || G <- ?UNZIP_MODES],

    ZipGroup ++ Zip64Group.

z64(Mode) when is_atom(Mode) ->
    list_to_atom(lists:concat([z64_,Mode]));
z64(Modes) when is_list(Modes) ->
    [z64(M) || M <- Modes].

un_z64(Mode) ->
    case atom_to_list(Mode) of
        "z64_" ++ ModeString -> list_to_atom(ModeString);
        _ -> Mode
    end.

zip_testcases() ->
    [mode, basic_timestamp, extended_timestamp,
     capped_timestamp, uid_gid, sanitize_filenames].

zip64_testcases() ->
    [unzip64_central_headers,
     zip64_central_directory].

init_per_suite(Config) ->
    {ok, Started} = application:ensure_all_started(os_mon),
    cleanup_priv_dir(Config),
    [{started, Started} | Config].

end_per_suite(Config) ->
    [application:stop(App) || App <- lists:reverse(get_value(started, Config))],
    cleanup_priv_dir(Config),
    ok.

cleanup_priv_dir(Config) ->
    %% Cleanup potential files in priv_dir
    Pdir = get_value(pdir, Config, get_value(priv_dir,Config)),
    ct:log("Cleaning up ~s",[Pdir]),
    [ case file:delete(File) of
        {error, eperm} -> file:del_dir_r(File);
        _ -> ok
    end || File <- filelib:wildcard(filename:join(Pdir, "*"))].

init_per_group(zip64_group, Config) ->
    PrivDir = get_value(priv_dir, Config),

    SkipZip64 = string:find(os:getenv("TS_EXTRA_PLATFORM_LABEL",""), "Docker") =/= nomatch,
    WordSize = erlang:system_info(wordsize),
    DiskFreeKB = disc_free(PrivDir),
    MemFreeB = memsize(),

    if SkipZip64 ->
            {skip, "Zip64 tests unstable on docker, do not run"};
       WordSize =:= 4 ->
            {skip, "Zip64 tests only work on 64-bit systems"};
       DiskFreeKB =:= error ->
            {skip, "Failed to query disk space for priv_dir. "
             "Is it on a remote file system?~n"};
       DiskFreeKB >= 16 * (1 bsl 20), MemFreeB >= ?EMZIP64_MEM_USAGE ->
            ct:log("Free disk: ~w KByte~n", [DiskFreeKB]),
            ct:log("Free memory: ~w MByte~n", [MemFreeB div (1 bsl 20)]),
            OneMB = <<0:(8 bsl 20)>>,
            Large4GB = filename:join(PrivDir, "large.txt"),
            ok = file:write_file(Large4GB, lists:duplicate(4 bsl 10, OneMB)),
            Medium4MB = filename:join(PrivDir, "medium.txt"),
            ok = file:write_file(Medium4MB, lists:duplicate(4, OneMB)),

            [{large, Large4GB},{medium,Medium4MB}|Config];
        true ->
            ct:log("Free disk: ~w KByte~n", [DiskFreeKB]),
            ct:log("Free memory: ~w MByte~n", [MemFreeB div (1 bsl 20)]),
            {skip,"Less than 16 GByte free disk or less then 8 GB free mem"}
    end;
init_per_group(Group, Config) ->
    case lists:member(Group, ?ZIP_MODES ++ ?UNZIP_MODES ++ z64(?ZIP_MODES ++ ?UNZIP_MODES)) of
        true ->
            case get_value(zip, Config) of
                undefined ->
                    case un_z64(Group) =/= zip orelse has_zip() of
                        true ->
                            Pdir = filename:join(get_value(priv_dir, Config),Group),
                            ok = filelib:ensure_path(Pdir),
                            [{pdir, Pdir},{zip, Group} | Config];
                        false ->
                            {skip, "No zip program found"}
                    end;
                _Zip ->
                    case un_z64(Group) =/= unzip orelse has_zip() of
                        true ->
                            Pdir = filename:join(get_value(pdir, Config),Group),
                            ok = filelib:ensure_path(Pdir),
                            [{pdir, Pdir},{unzip, Group} | Config];
                        false ->
                            {skip, "No zip program found"}
                    end
            end;
        false ->
            Config
    end.

end_per_group(_GroupName, Config) ->
    cleanup_priv_dir(Config),
    Config.

init_per_testcase(TC, Config) ->
    UsesZip = un_z64(get_value(zip, Config)) =:= zip orelse un_z64(get_value(unzip, Config)) =:= unzip,
    HasZip = has_zip(),
    ct:log("Free memory: ~w MByte~n", [memsize() div (1 bsl 20)]),
    if UsesZip andalso not HasZip ->
            {skip, "No zip command found"};
       true ->
            PrivDir = filename:join(get_value(pdir, Config,get_value(priv_dir, Config)), TC),
            ok = filelib:ensure_path(PrivDir),
            [{pdir, PrivDir} | Config]
    end.


end_per_testcase(_TC, Config) ->
    cleanup_priv_dir(Config),
    Config.

%% Test creating, listing and extracting one file from an archive
%% multiple times with different file sizes. Also check that the
%% modification date of the extracted file has survived.
borderline(Config) when is_list(Config) ->
    RootDir = get_value(priv_dir, Config),
    TempDir = filename:join(RootDir, "borderline"),

    Record = 512,
    Block = 20 * Record,

    lists:foreach(fun(Size) -> borderline_test(Size, TempDir) end,
                  [0, 1, 10, 13, 127, 333, Record-1, Record, Record+1,
                   Block-Record-1, Block-Record, Block-Record+1,
                   Block-1, Block, Block+1,
                   Block+Record-1, Block+Record, Block+Record+1]),

    %% Clean up.
    delete_files([TempDir]),
    ok.

borderline_test(Size, TempDir) ->
    Archive = filename:join(TempDir, "ar_"++integer_to_list(Size)++".zip"),
    Name = filename:join(TempDir, "file_"++integer_to_list(Size)),
    io:format("Testing size ~p", [Size]),

    %% Create a file and archive it.
    {_, _, X0} = erlang:timestamp(),
    file:write_file(Name, random_byte_list(X0, Size)),
    {ok, Archive} = zip:zip(Archive, [Name]),
    ok = file:delete(Name),

    RelName = filename:join(tl(filename:split(Name))),

    %% Verify listing and extracting.
    {ok, [#zip_comment{comment = []},
          #zip_file{name = RelName,
                    info = Info,
                    offset = 0,
                    comp_size = _}]} = zip:list_dir(Archive),
    Size = Info#file_info.size,
    TempRelName = filename:join(TempDir, RelName),
    {ok, [TempRelName]} = zip:extract(Archive, [verbose, {cwd, TempDir}]),

    %% Verify that absolute file was not created
    {error, enoent} = file:read_file(Name),

    %% Verify that relative contents of extracted file.
    {ok, Bin} = file:read_file(TempRelName),
    true = match_byte_list(X0, binary_to_list(Bin)),

    %% Verify that Unix zip can read it. (if we have a unix zip that is!)
    zipinfo_match(Archive, RelName),

    ok.

zipinfo_match(Archive, Name) ->
    case check_zipinfo_exists() of
        true ->
            Encoding = file:native_name_encoding(),
            Expect = unicode:characters_to_binary(Name ++ "\n",
                                                  Encoding, Encoding),
            cmd_expect("zipinfo -1 " ++ Archive, Expect);
        _ ->
            ok
    end.

check_zipinfo_exists() ->
    is_list(os:find_executable("zipinfo")).

cmd_expect(Cmd, Expect) ->
    Port = open_port({spawn, make_cmd(Cmd)}, [stream, in, binary, eof]),
    get_data(Port, Expect, <<>>).

get_data(Port, Expect, Acc) ->
    receive
        {Port, {data, Bytes}} ->
            get_data(Port, Expect, <<Acc/binary, Bytes/binary>>);
        {Port, eof} ->
            Port ! {self(), close},
            receive
                {Port, closed} ->
                    true
            end,
            receive
                {'EXIT',  Port,  _} ->
                    ok
            after 1 ->                          % force context switch
                    ok
            end,
            match_output(Acc, Expect, Port)
    end.

match_output(<<C, Output/bits>>, <<C,Expect/bits>>, Port) ->
    match_output(Output, Expect, Port);
match_output(<<_, _/bits>>, <<_, _/bits>>, Port) ->
    kill_port_and_fail(Port, badmatch);
match_output(<<_, _/bits>>=Rest, <<>>, Port) ->
    kill_port_and_fail(Port, {too_much_data, Rest});
match_output(<<>>, <<>>, _Port) ->
    ok.

kill_port_and_fail(Port, Reason) ->
    unlink(Port),
    exit(Port, die),
    ct:fail(Reason).

make_cmd(Cmd) ->
    Cmd.
%%     case os:type() of
%%      {win32, _} -> lists:concat(["cmd /c",  Cmd]);
%%      {unix, _}  -> lists:concat(["sh -c '",  Cmd,  "'"])
%%     end.

%% Verifies a random byte list.

match_byte_list(X0, [Byte|Rest]) ->
    X = next_random(X0),
    case (X bsr 26) band 16#ff of
        Byte -> match_byte_list(X, Rest);
        _ -> false
    end;
match_byte_list(_, []) ->
    true.

%% Generates a random byte list.

random_byte_list(X0, Count) ->
    random_byte_list(X0, Count, []).

random_byte_list(X0, Count, Result) when Count > 0->
    X = next_random(X0),
    random_byte_list(X, Count-1, [(X bsr 26) band 16#ff|Result]);
random_byte_list(_X, 0, Result) ->
    lists:reverse(Result).

%% This RNG is from line 21 on page 102 in Knuth: The Art of Computer Programming,
%% Volume II, Seminumerical Algorithms.

next_random(X) ->
    (X*17059465+1) band 16#fffffffff.

%% Test the 'atomic' operations: zip/unzip/list_dir, on archives.
%% Also test the 'cooked' option.
atomic(Config) when is_list(Config) ->
    ok = file:set_cwd(get_value(priv_dir, Config)),
    DataFiles = data_files(),
    Names = [Name || {Name,_,_} <- DataFiles],
    io:format("Names: ~p", [Names]),

    %% Create a zip  archive.

    Zip2 = "zip.zip",
    {ok, Zip2} = zip:zip(Zip2, Names, []),
    Names = names_from_list_dir(zip:list_dir(Zip2)),

    %% Same test again, but this time created with 'cooked'

    Zip3 = "cooked.zip",
    {ok, Zip3} = zip:zip(Zip3, Names, [cooked]),
    Names = names_from_list_dir(zip:list_dir(Zip3)),
    Names = names_from_list_dir(zip:list_dir(Zip3, [cooked])),

    %% Clean up.
    delete_files([Zip2,Zip3|Names]),

    ok.

%% Test the zip_open/2, zip_get/1, zip_get/2, zip_close/1,
%% and zip_list_dir/1 functions.
zip_api(Config) when is_list(Config) ->
    ok = file:set_cwd(get_value(priv_dir, Config)),
    DataFiles = data_files(),
    Names = [Name || {Name, _, _} <- DataFiles],
    io:format("Names: ~p", [Names]),

    %% Create a zip archive
    Zip = "zip.zip",
    {ok, Zip} = zip:zip(Zip, Names, []),

    %% Open archive
    {ok, ZipSrv} = zip:zip_open(Zip, [memory]),

    %% List dir
    Names = names_from_list_dir(zip:zip_list_dir(ZipSrv)),

    %% Get a file
    Name1 = hd(Names),
    {ok, Data1} = file:read_file(Name1),
    {ok, {Name1, Data1}} = zip:zip_get(Name1, ZipSrv),
    Data1Crc = erlang:crc32(Data1),
    {ok, Data1Crc} = zip:zip_get_crc32(Name1, ZipSrv),

    %% Get all files
    FilesDatas = lists:map(fun(Name) -> {ok, B} = file:read_file(Name),
                                        {Name, B} end, Names),
    {ok, FilesDatas} = zip:zip_get(ZipSrv),

    %% Close
    ok = zip:zip_close(ZipSrv),

    %% Clean up.
    delete_files([Names]),

    ok.

%% Test that zip doesn't leak processes and ports where the
%% controlling process dies without closing an zip opened with
%% zip:zip_open/1.
open_leak(Config) when is_list(Config) ->
    %% Create a zip archive
    Zip = "zip.zip",
    {ok, Zip} = zip:zip(Zip, [], []),

    %% Open archive in a another process that dies immediately.
    ZipSrv = spawn_zip(Zip, [memory]),

    %% Expect the ZipSrv process to die soon after.
    true = spawned_zip_dead(ZipSrv),

    %% Clean up.
    delete_files([Zip]),

    ok.

spawn_zip(Zip, Options) ->
    Self = self(),
    spawn(fun() -> Self ! zip:zip_open(Zip, Options) end),
    receive
        {ok, ZipSrv} ->
            ZipSrv
    end.

spawned_zip_dead(ZipSrv) ->
    Ref = monitor(process, ZipSrv),
    receive
        {'DOWN', Ref, _, ZipSrv, _} ->
            true
    after 1000 ->
            false
    end.

%% Test options for unzip, only cwd, file_list and keep_old_files currently.
unzip_options(Config) when is_list(Config) ->
    DataDir = get_value(data_dir, Config),
    PrivDir = get_value(priv_dir, Config),
    Long = filename:join(DataDir, "abc.zip"),

    %% create a temp directory
    Subdir = filename:join(PrivDir, "t"),
    ok = file:make_dir(Subdir),

    FList = ["quotes/rain.txt","wikipedia.txt"],

    %% Unzip a zip file in Subdir
    {ok, RetList} = zip:unzip(Long, [{cwd, Subdir},
				     {file_list, FList}]),

    %% Verify.
    true = (length(FList) =:= length(RetList)),
    lists:foreach(fun(F)-> {ok,B} = file:read_file(filename:join(DataDir, F)),
			   {ok,B} = file:read_file(filename:join(Subdir, F)) end,
		  FList),
    lists:foreach(fun(F)-> ok = file:delete(F) end,
		  RetList),

    %% Clean up and verify no more files.
    0 = delete_files([Subdir]),

    FList2 = ["abc.txt","quotes/rain.txt","wikipedia.txt","emptyFile"],

    %% Unzip a zip file in Subdir
    {ok, RetList2} = zip:unzip(Long, [{cwd, Subdir},skip_directories]),

    %% Verify.
    true = (length(RetList2) =:= 4),
    lists:foreach(fun(F)-> {ok,B} = file:read_file(filename:join(DataDir, F)),
			   {ok,B} = file:read_file(filename:join(Subdir, F)) end,
		  FList2),
    lists:foreach(fun(F)-> 1 = delete_files([F]) end,
		  RetList2),

    %% Clean up and verify no more files.
    0 = delete_files([Subdir]),

    OriginalFile1 = filename:join(Subdir, "abc.txt"),
    OriginalFile2 = filename:join(Subdir, "quotes/rain.txt"),

    ok = file:make_dir(filename:dirname(OriginalFile1)),
    ok = file:write_file(OriginalFile1, ["Original 1"]),
    ok = file:make_dir(filename:dirname(OriginalFile2)),
    ok = file:write_file(OriginalFile2, ["Original 2"]),

    FList3 = ["wikipedia.txt","emptyFile"],

    %% Unzip a zip file in Subdir
    {ok, RetList3} = zip:unzip(Long, [{cwd, Subdir},skip_directories,keep_old_files]),
    {ok, []} = zip:unzip(Long, [{cwd, Subdir},skip_directories,keep_old_files]),

    %% Verify.
    true = (length(RetList3) =:= 2),
    {ok,<<"Original 1">>} = file:read_file(OriginalFile1),
    {ok,<<"Original 2">>} = file:read_file(OriginalFile2),
    lists:foreach(fun(F)-> {ok,B} = file:read_file(filename:join(DataDir, F)),
			   {ok,B} = file:read_file(filename:join(Subdir, F)) end,
		  FList3),
    lists:foreach(fun(F)-> 1 = delete_files([F]) end,
		  RetList3),

    %% Clean up and verify no more files.
    2 = delete_files([OriginalFile1, OriginalFile2]),
    0 = delete_files([Subdir]),
    ok.

%% Test that unzip handles directory traversal exploit (OTP-13633)
unzip_traversal_exploit(Config) ->
    DataDir = get_value(data_dir, Config),
    PrivDir = get_value(priv_dir, Config),
    ZipName = filename:join(DataDir, "exploit.zip"),

    %% $ zipinfo -1 test/zip_SUITE_data/exploit.zip 
    %% clash.txt
    %% ../clash.txt
    %% ../above.txt
    %% subdir/../in_root_dir.txt

    %% create a temp directory
    SubDir = filename:join(PrivDir, "exploit_test"),
    ok = file:make_dir(SubDir),
    
    ClashFile = filename:join(SubDir,"clash.txt"),
    AboveFile = filename:join(SubDir,"above.txt"),
    RelativePathFile = filename:join(SubDir,"subdir/../in_root_dir.txt"),

    %% unzip in SubDir
    {ok, [ClashFile, ClashFile, AboveFile, RelativePathFile]} =
	zip:unzip(ZipName, [{cwd,SubDir}]),

    {ok,<<"This file will overwrite other file.\n">>} =
	file:read_file(ClashFile),
    {ok,_} = file:read_file(AboveFile),
    {ok,_} = file:read_file(RelativePathFile),

    %% clean up
    delete_files([SubDir]),
    
     %% create the temp directory again
    ok = file:make_dir(SubDir),

    %% unzip in SubDir
    {ok, [ClashFile, AboveFile, RelativePathFile]} =
	zip:unzip(ZipName, [{cwd,SubDir},keep_old_files]),

    {ok,<<"This is the original file.\n">>} =
	file:read_file(ClashFile),
   
    %% clean up
    delete_files([SubDir]),
    ok.

%% Test unzip a jar file (OTP-7382).
unzip_jar(Config) when is_list(Config) ->
    DataDir = get_value(data_dir, Config),
    PrivDir = get_value(priv_dir, Config),
    JarFile = filename:join(DataDir, "test.jar"),

    %% create a temp directory
    Subdir = filename:join(PrivDir, "jartest"),
    ok = file:make_dir(Subdir),

    FList = ["META-INF/MANIFEST.MF","test.txt"],

    {ok, RetList} = zip:unzip(JarFile, [{cwd, Subdir}]),

    %% Verify.
    lists:foreach(fun(F)-> {ok,B} = file:read_file(filename:join(DataDir, F)),
			   {ok,B} = file:read_file(filename:join(Subdir, F)) end,
		  FList),
    lists:foreach(fun(F)->
                          case lists:last(F) =:= $/ of
                              true -> ok = file:del_dir(F);
                              false -> ok = file:delete(F)
                          end
                  end,
		  lists:reverse(RetList)),

    %% Clean up and verify no more files.
    0 = delete_files([Subdir]),
    ok.

%% Test the options for unzip, only cwd currently.
zip_options(Config) when is_list(Config) ->
    PrivDir = get_value(priv_dir, Config),
    ok = file:set_cwd(PrivDir),
    DataFiles = data_files(),
    Names = [Name || {Name, _, _} <- DataFiles],

    %% Make sure cwd is not where we get the files
    ok = file:set_cwd(get_value(data_dir, Config)),

    %% Create a zip archive
    {ok, {_,Zip}} =
        zip:zip("filename_not_used.zip", Names, [memory, {cwd, PrivDir}]),

    %% Open archive
    {ok, ZipSrv} = zip:zip_open(Zip, [memory]),

    %% List dir
    Names = names_from_list_dir(zip:zip_list_dir(ZipSrv)),

    %% Get a file
    Name1 = hd(Names),
    {ok, Data1} = file:read_file(filename:join(PrivDir, Name1)),
    {ok, {Name1, Data1}} = zip:zip_get(Name1, ZipSrv),

    %% Get all files
    FilesDatas = lists:map(fun(Name) -> {ok, B} = file:read_file(filename:join(PrivDir, Name)),
                                        {Name, B} end, Names),
    {ok, FilesDatas} = zip:zip_get(ZipSrv),

    %% Close
    ok = zip:zip_close(ZipSrv),

    %% Clean up.
    delete_files([Names]),

    ok.

%% Test the options for list_dir... one day.
list_dir_options(Config) when is_list(Config) ->

    DataDir = get_value(data_dir, Config),
    Archive = filename:join(DataDir, "abc.zip"),

    {ok,
     ["abc.txt", "quotes/rain.txt", "empty/", "wikipedia.txt", "emptyFile" ]} =
        zip:list_dir(Archive,[names_only]),

    {ok,
     [#zip_comment{},
      #zip_file{ name = "abc.txt" },
      #zip_file{ name = "quotes/rain.txt" },
      #zip_file{ name = "wikipedia.txt" },
      #zip_file{ name = "emptyFile" }
     ]} =  zip:list_dir(Archive,[skip_directories]),

    ok.

%% convert zip_info as returned from list_dir to a list of names
names_from_list_dir({ok, Info}) ->
    names_from_list_dir(Info);
names_from_list_dir(Info) ->
    tl(lists:map(fun(#zip_file{name = Name}) -> Name;
                    (_) -> ok end, Info)).

%% Returns a sequence of characters.
char_seq(N, First) ->
    char_seq(N, First, []).

char_seq(0, _, Result) ->
    Result;
char_seq(N, C, Result) when C < 127 ->
    char_seq(N-1, C+1, [C|Result]);
char_seq(N, _, Result) ->
    char_seq(N, $!, Result).

data_files() ->
    Files = [{"first_file", 1555, $a},
             {"small_file", 7, $d},
             {"big_file", 23875, $e},
             {"last_file", 7500, $g}],
    create_files(Files),
    Files.

create_files([{Name, dir, _First}|Rest]) ->
    ok = file:make_dir(Name),
    create_files(Rest);
create_files([{Name, Size, First}|Rest]) when is_integer(Size) ->
    ok = file:write_file(Name, char_seq(Size, First)),
    create_files(Rest);
create_files([]) ->
    ok.

%% make_dirs([Dir|Rest], []) ->
%%     ok = file:make_dir(Dir),
%%     make_dirs(Rest, Dir);
%% make_dirs([Dir|Rest], Parent) ->
%%     Name = filename:join(Parent, Dir),
%%     ok = file:make_dir(Name),
%%     make_dirs(Rest, Name);
%% make_dirs([], Dir) ->
%%     Dir.

%% Try zip:unzip/1 on some corrupted zip files.
bad_zip(Config) when is_list(Config) ->
    ok = file:set_cwd(get_value(priv_dir, Config)),
    try_bad("bad_crc",    {"abc.txt", bad_crc}, Config),
    try_bad("bad_central_directory", bad_central_directory, Config),
    try_bad("bad_file_header",    bad_file_header, Config),
    try_bad("bad_eocd",    bad_eocd, Config),
    try_bad("enoent", enoent, Config),
    GetNotFound = fun(A) ->
                          {ok, O} = zip:zip_open(A, []),
                          zip:zip_get("not_here", O)
                  end,
    try_bad("abc", file_not_found, GetNotFound, Config),
    ok.

try_bad(N, R, Config) ->
    try_bad(N, R, fun(A) -> io:format("name : ~p\n", [A]),
                            zip:unzip(A, [verbose]) end, Config).

try_bad(Name0, Reason, What, Config) ->
    %% Intentionally no macros here.

    DataDir = get_value(data_dir, Config),
    Name = Name0 ++ ".zip",
    io:format("~nTrying ~s", [Name]),
    Full = filename:join(DataDir, Name),
    Expected = {error, Reason},
    case What(Full) of
        Expected ->
            io:format("Result: ~p\n", [Expected]);
        Other ->
            io:format("unzip/2 returned ~p (expected ~p)\n", [Other, Expected]),
            ct:fail({bad_return_value, Other})
    end.

%% Test extracting to binary with memory option.
unzip_to_binary(Config) when is_list(Config) ->
    DataDir = get_value(data_dir, Config),
    PrivDir = get_value(priv_dir, Config),
    WorkDir = filename:join(PrivDir, "unzip_to_binary"),
    _ = file:make_dir(WorkDir),
    _ = file:make_dir(filename:join(DataDir, "empty")),

    ok = file:set_cwd(WorkDir),
    Long = filename:join(DataDir, "abc.zip"),

    %% Unzip a zip file into a binary
    {ok, FBList} = zip:unzip(Long, [memory]),

    %% Verify.
    lists:foreach(fun({F,B}) ->
                          Filename = filename:join(DataDir, F),
                          case lists:last(F) =:= $/ of
                              true ->
                                  <<>> = B,
                                  {ok, #file_info{ type = directory}} =
                                      file:read_file_info(Filename);
                              false ->
                                  {ok,B}=file:read_file(filename:join(DataDir, F))
                          end
                  end, FBList),

    %% Make sure no files created in cwd
    {ok,[]} = file:list_dir(WorkDir),

    ok.

%% Test compressing to binary with memory option.
zip_to_binary(Config) when is_list(Config) ->
    DataDir = get_value(data_dir, Config),
    PrivDir = get_value(priv_dir, Config),
    WorkDir = filename:join(PrivDir, "zip_to_binary"),
    _ = file:make_dir(WorkDir),

    file:set_cwd(WorkDir),
    FileName = "abc.txt",
    ZipName = "t.zip",
    FilePath = filename:join(DataDir, FileName),
    {ok, _Size} = file:copy(FilePath, FileName),

    %% Zip to a binary archive
    {ok, {ZipName, ZipB}} = zip:zip(ZipName, [FileName], [memory]),

    %% Make sure no files created in cwd
    {ok,[FileName]} = file:list_dir(WorkDir),

    %% Zip to a file
    {ok, ZipName} = zip:zip(ZipName, [FileName]),

    %% Verify.
    {ok, ZipB} = file:read_file(ZipName),
    {ok, FData} = file:read_file(FileName),
    {ok, [{FileName, FData}]} = zip:unzip(ZipB, [memory]),

    %% Clean up.
    delete_files([FileName, ZipName]),

    ok.

%% Test using the aliases, extract/2, table/2 and create/3.
aliases(Config) when is_list(Config) ->
    {_, _, X0} = erlang:timestamp(),
    Size = 100,
    B = list_to_binary(random_byte_list(X0, Size)),
    %% create
    {ok, {"z.zip", ZArchive}} = zip:create("z.zip", [{"b", B}], [memory]),
    %% extract
    {ok, [{"b", B}]} = zip:extract(ZArchive, [memory]),
    %% table
    {ok, [#zip_comment{comment = _}, #zip_file{name = "b",
                                               info = FI,
                                               comp_size = _,
                                               offset = 0}]} =
        zip:table(ZArchive),
    Size = FI#file_info.size,

    ok.



%% Test extracting a zip archive from a binary.
unzip_from_binary(Config) when is_list(Config) ->
    DataDir = get_value(data_dir, Config),
    PrivDir = get_value(priv_dir, Config),
    ExtractDir = filename:join(PrivDir, "extract_from_binary"),
    Archive = filename:join(ExtractDir, "abc.zip"),

    ok = file:make_dir(ExtractDir),
    {ok, _Size} = file:copy(filename:join(DataDir, "abc.zip"), Archive),
    FileName = "abc.txt",
    Quote = "quotes/rain.txt",
    Wikipedia = "wikipedia.txt",
    EmptyFile = "emptyFile",
    EmptyDir = "empty/",
    file:set_cwd(ExtractDir),

    %% Read a zip file into a binary and extract from the binary.
    {ok, Bin} = file:read_file(Archive),
    {ok, [FileName,Quote,EmptyDir,Wikipedia,EmptyFile]} = zip:unzip(Bin),

    %% Verify.
    DestFilename = filename:join(ExtractDir, "abc.txt"),
    {ok, Data} = file:read_file(filename:join(DataDir, FileName)),
    {ok, Data} = file:read_file(DestFilename),

    DestQuote = filename:join([ExtractDir, "quotes", "rain.txt"]),
    {ok, QuoteData} = file:read_file(filename:join(DataDir, Quote)),
    {ok, QuoteData} = file:read_file(DestQuote),

    %% Don't be in ExtractDir when we delete it
    ok = file:set_cwd(PrivDir),

    %% Clean up.
    delete_files([DestFilename, DestQuote, Archive, ExtractDir]),

    ok = file:make_dir(ExtractDir),
    file:set_cwd(ExtractDir),

    %% Read a zip file into a binary and extract from the binary with skip_directories
    {ok, [FileName,Quote,Wikipedia,EmptyFile]}
        = zip:unzip(Bin, [skip_directories]),

    %% Verify.
    DestFilename = filename:join(ExtractDir, "abc.txt"),
    {ok, Data} = file:read_file(filename:join(DataDir, FileName)),
    {ok, Data} = file:read_file(DestFilename),

    DestQuote = filename:join([ExtractDir, "quotes", "rain.txt"]),
    {ok, QuoteData} = file:read_file(filename:join(DataDir, Quote)),
    {ok, QuoteData} = file:read_file(DestQuote),

    %% Clean up.
    delete_files([DestFilename, DestQuote, ExtractDir]),

    ok.

%% oac_files() ->
%%     Files = [{"oac_file", 1459, $x},
%%           {"oac_small", 99, $w},
%%           {"oac_big", 33896, $A}],
%%     create_files(Files),
%%     Files.

%% Delete the given list of files and directories.
%% Return total number of deleted files (not directories)
delete_files(List) ->
    do_delete_files(List, 0).
do_delete_files([],Cnt) ->
    Cnt;
do_delete_files([Item|Rest], Cnt) ->
    case file:delete(Item) of
        ok ->
            DelCnt = 1;
        {error,eperm} ->
            file:change_mode(Item, 8#777),
            DelCnt = delete_files(filelib:wildcard(filename:join(Item, "*"))),
            file:del_dir(Item);
        {error,eacces} ->
            %% We'll see about that!
            file:change_mode(Item, 8#777),
            case file:delete(Item) of
                ok ->
		    DelCnt = 1;
                {error,_} ->
                    erlang:yield(),
                    file:change_mode(Item, 8#777),
                    file:delete(Item),
                    DelCnt = 1
            end;
        {error,_} ->
            DelCnt = 0
    end,
    do_delete_files(Rest, Cnt + DelCnt).

%% Test control of which files that should be compressed.
compress_control(Config) when is_list(Config) ->
    ok = file:set_cwd(get_value(priv_dir, Config)),
    Dir = "compress_control",
    Files = [
             {Dir,                                                          dir,   $d},
             {filename:join([Dir, "first_file.txt"]), 10000, $f},
             {filename:join([Dir, "a_dir"]), dir,   $d},
             {filename:join([Dir, "a_dir", "zzz.zip"]), 10000, $z},
             {filename:join([Dir, "a_dir", "lll.lzh"]), 10000, $l},
             {filename:join([Dir, "a_dir", "eee.exe"]), 10000, $e},
             {filename:join([Dir, "a_dir", "ggg.arj"]), 10000, $g},
             {filename:join([Dir, "a_dir", "b_dir"]), dir,   $d},
             {filename:join([Dir, "a_dir", "b_dir", "ggg.arj"]), 10000, $a},
             {filename:join([Dir, "last_file.txt"]), 10000, $l}
            ],

    test_compress_control(Dir,
			  Files,
			  [{compress, []}],
			  []),

    test_compress_control(Dir,
			  Files,
			  [{uncompress, all}],
			  []),

    test_compress_control(Dir,
			  Files,
			  [{uncompress, []}],
			  [".txt", ".exe", ".zip", ".lzh", ".arj"]),

    test_compress_control(Dir,
			  Files,
			  [],
			  [".txt", ".exe"]),

    test_compress_control(Dir,
			  Files,
			  [{uncompress, {add, [".exe"]}},
			   {uncompress, {del, [".zip", "arj"]}}],
			  [".txt", ".zip", "arj"]),

    test_compress_control(Dir,
			  Files,
			  [{uncompress, []},
			   {uncompress, {add, [".exe"]}},
			   {uncompress, {del, [".zip", "arj"]}}],
			  [".txt", ".zip", ".lzh", ".arj"]),

    ok.

test_compress_control(Dir, Files, ZipOptions, Expected) ->
    %% Cleanup
    Zip = "zip.zip",
    Names = [N || {N, _, _} <- Files],
    delete_files([Zip]),
    delete_files(lists:reverse(Names)),

    create_files(Files),
    {ok, Zip} = zip:create(Zip, [Dir], ZipOptions),

    {ok, OpenZip} = zip:zip_open(Zip, [memory]),
    {ok,[#zip_comment{comment = ""} | ZipList]} = zip:zip_list_dir(OpenZip),
    io:format("compress_control:  -> ~p  -> ~p\n  -> ~pn", [Expected, ZipOptions, ZipList]),
    verify_compression(Files, ZipList, OpenZip, ZipOptions, Expected),
    ok = zip:zip_close(OpenZip),

    %% Cleanup
    delete_files([Zip]),
    delete_files(lists:reverse(Names)), % Remove plain files before directories

    ok.

verify_compression([{Name, Kind, _Filler} | Files], ZipList, OpenZip, ZipOptions, Expected) ->
    {Name2, BinSz} =
        case Kind of
            dir ->
                {Name ++ "/", 0};
            _   ->
                {ok, {Name, Bin}} = zip:zip_get(Name, OpenZip),
                {Name, size(Bin)}
        end,
    {Name2, {value, ZipFile}} = {Name2, lists:keysearch(Name2,  #zip_file.name, ZipList)},
    #zip_file{info = #file_info{size = InfoSz, type = InfoType}, comp_size = InfoCompSz} = ZipFile,

    Ext = filename:extension(Name),
    IsComp = is_compressed(Ext, Kind, ZipOptions),
    ExpComp = lists:member(Ext, Expected),
    case {Name, Kind, InfoType, IsComp, ExpComp, BinSz, InfoSz, InfoCompSz} of
        {_, dir, directory, false, _,     Sz, Sz, Sz}      when Sz =:= BinSz -> ok;
        {_, Sz,  regular,   false, false, Sz, Sz, Sz}      when Sz =:= BinSz -> ok;
        {_, Sz,  regular,   true,  true,  Sz, Sz, OtherSz} when Sz =:= BinSz, OtherSz =/= BinSz -> ok
    end,
    verify_compression(Files, ZipList -- [ZipFile], OpenZip, ZipOptions, Expected);
verify_compression([], [], _OpenZip, _ZipOptions, _Expected) ->
    ok.

is_compressed(_Ext, dir, _Options) ->
    false;
is_compressed(Ext, _Sz, Options) ->
    CompressOpt =
        case [What || {compress, What} <- Options] of
            [] -> all;
            CompressOpts-> extensions(CompressOpts, all)
        end,
    DoCompress = (CompressOpt =:= all) orelse lists:member(Ext, CompressOpt),
    Default = [".Z", ".zip", ".zoo", ".arc", ".lzh", ".arj"],
    UncompressOpt =
        case [What || {uncompress, What} <- Options] of
            [] -> Default;
            UncompressOpts-> extensions(UncompressOpts, Default)
        end,
    DoUncompress = (UncompressOpt =:= all) orelse lists:member(Ext, UncompressOpt),
    DoCompress andalso not DoUncompress.

extensions([H | T], Old) ->
    case H of
        all ->
            extensions(T, H);
        H when is_list(H) ->
            extensions(T, H);
        {add, New} when is_list(New), is_list(Old) ->
            extensions(T, Old ++ New);
        {del, New} when is_list(New), is_list(Old) ->
            extensions(T, Old -- New);
        _ ->
            extensions(T, Old)
    end;
extensions([], Old) ->
    Old.

foldl(Config) ->
    PrivDir = get_value(priv_dir, Config),
    File = filename:join([PrivDir, "foldl.zip"]),

    FooBin = <<"FOO">>,
    BarBin = <<"BAR">>,
    Files = [{"foo", FooBin}, {"bar", BarBin}],
    {ok, {File, Bin}} = zip:create(File, Files, [memory,{extra,[]}]),
    ZipFun = fun(N, I, B, Acc) -> [{N, B(), I()} | Acc] end,
    {ok, FileSpec} = zip:foldl(ZipFun, [], {File, Bin}),
    [{"bar", BarBin, #file_info{}}, {"foo", FooBin, #file_info{}}] = FileSpec,
    {ok, {File, Bin}} = zip:create(File, lists:reverse(FileSpec), [memory,{extra,[]}]),
    {foo_bin, FooBin} =
	try
	    zip:foldl(fun("foo", _, B, _) -> throw(B()); (_, _, _, Acc) -> Acc end, [], {File, Bin})
	catch
	    throw:FooBin ->
		{foo_bin, FooBin}
	end,
    ok = file:write_file(File, Bin),
    {ok, FileSpec} = zip:foldl(ZipFun, [], File),

    {error, einval} = zip:foldl(fun() -> ok end, [], File),
    {error, einval} = zip:foldl(ZipFun, [], 42),
    {error, einval} = zip:foldl(ZipFun, [], {File, 42}),

    ok = file:delete(File),
    {error, enoent} = zip:foldl(ZipFun, [], File),

    ok.

fd_leak(Config) ->
    ok = file:set_cwd(get_value(priv_dir, Config)),
    DataDir = get_value(data_dir, Config),
    Name = filename:join(DataDir, "bad_file_header.zip"),
    BadExtract = fun() ->
                         {error,bad_file_header} = zip:extract(Name),
                         ok
                 end,
    do_fd_leak(BadExtract, 1),

    BadCreate = fun() ->
                        {error,{"none", {_, enoent}}} = zip:zip("failed.zip",
                                                      ["none"]),
                        ok
                end,
    do_fd_leak(BadCreate, 1),

    ok.

do_fd_leak(_Bad, 10000) ->
    ok;
do_fd_leak(Bad, N) ->
    try Bad() of
        ok ->
            do_fd_leak(Bad, N + 1)
    catch
        C:R:Stk ->
            io:format("Bad error after ~p attempts\n", [N]),
            erlang:raise(C, R, Stk)
    end.

unicode(Config) ->
    case file:native_name_encoding() of
        latin1 ->
            {comment, "Native name encoding is Latin-1; skipping all tests"};
        utf8 ->
            DataDir = get_value(data_dir, Config),
            ok = file:set_cwd(get_value(priv_dir, Config)),
            test_file_comment(DataDir),
            test_archive_comment(DataDir),
            test_bad_comment(DataDir),
            test_latin1_archive(DataDir),
            case has_zip() of
                false ->
                    {comment, "No zip program found; skipping some tests"};
                true ->
                    case zip_is_unicode_aware() of
                        true ->
                            test_filename_compatibility(),
                            ok;
                        false ->
                            {comment, "Old zip program; skipping some tests"}
                    end
            end
    end.

test_filename_compatibility() ->
    FancyName = "üñíĉòdë한",
    Archive = "test.zip",

    {ok, Archive} = zip:zip(Archive, [{FancyName, <<"test">>}]),
    zipinfo_match(Archive, FancyName).

test_file_comment(DataDir) ->
    Archive = filename:join(DataDir, "zip_file_comment.zip"),
    Comments = ["a", [246], [1024]],
    FileNames = [[C] ++ ".txt" || C <- [$a, 246, 1024]],
    [begin
         test_zip_file(FileName, Comment, Archive),
         test_file_comment(FileName, Comment, Archive)
     end ||
        Comment <- Comments, FileName <- FileNames],
    ok.

test_zip_file(FileName, Comment, Archive) ->
    _ = file:delete(Archive),
    io:format("*** zip:zip(). Testing FileName ~ts, Comment ~ts\n",
              [FileName, Comment]),
    ok = file:write_file(FileName, ["anything"]),
    {ok, Archive} =
        zip:zip(Archive, [FileName], [verbose, {comment, Comment}]),
    zip_check(Archive, Comment, FileName, "").

test_file_comment(FileName, Comment, Archive) ->
    case test_zip1() of
        false ->
            ok;
        true ->
            _ = file:delete(Archive),
            io:format("*** zip(1). Testing FileName ~ts, Comment ~ts\n",
                      [FileName, Comment]),
            ok = file:write_file(FileName, ["anything"]),
            R = os:cmd("echo " ++ Comment ++ "| zip -c " ++
                           Archive ++ " " ++ FileName),
            io:format("os:cmd/1 returns ~lp\n", [R]),
            zip_check(Archive, "", FileName, Comment)
    end.

test_archive_comment(DataDir) ->
    Archive = filename:join(DataDir, "zip_archive_comment.zip"),
    Chars = [$a, 246, 1024],
    [test_archive_comment(Char, Archive) || Char <- Chars],
    ok.

test_archive_comment(Char, Archive) ->
    case test_zip1() of
        false ->
            ok;
        true ->
            _ = file:delete(Archive),
            FileName = "a.txt",
            Comment = [Char],
            io:format("*** Testing archive Comment ~ts\n", [Comment]),
            ok = file:write_file(FileName, ["anything"]),

            {ok, _} =
                zip:zip(Archive, [FileName], [verbose, {comment, Comment}]),
            Res = os:cmd("zip -z " ++ Archive),
            io:format("os:cmd/1 returns ~lp\n", [Res]),
            true = lists:member(Char, Res),

            os:cmd("echo " ++ Comment ++ "| zip -z "++
                       Archive ++ " " ++ FileName),
            zip_check(Archive, Comment, FileName, "")
    end.

test_zip1() ->
    has_zip() andalso zip_is_unicode_aware().

has_zip() ->
    os:find_executable("zip") =/= false andalso element(1, os:type()) =:= unix.

zip_is_unicode_aware() ->
    S = os:cmd("zip -v | grep 'UNICODE_SUPPORT'"),
    string:find(S, "UNICODE_SUPPORT") =/= nomatch.

zip_check(Archive, ArchiveComment, FileName, FileNameComment) ->
    {ok, CommentAndFiles} = zip:table(Archive),
    io:format("zip:table/1 returns\n  ~lp\n", [CommentAndFiles]),
    io:format("checking archive comment ~lp\n", [ArchiveComment]),
    [_] = [C || #zip_comment{comment = C} <- CommentAndFiles,
                C =:= ArchiveComment],
    io:format("checking filename ~lp\n", [FileName]),
    io:format("and filename comment ~lp\n", [FileNameComment]),
    [_] = [F || #zip_file{name = F, comment = C} <- CommentAndFiles,
                F =:= FileName, C =:= FileNameComment],
    {ok, FileList} = zip:unzip(Archive, [verbose]),
    io:format("zip:unzip/2 returns\n  ~lp\n", [FileList]),
    true = lists:member(FileName, FileList),
    ok.

test_bad_comment(DataDir) ->
    Archive = filename:join(DataDir, "zip_bad_comment.zip"),
    FileName = "a.txt",
    file:write_file(FileName, ["something"]),
    Comment = [9999999],
    {error,{bad_unicode,Comment}} =
        zip:zip(Archive, [FileName], [verbose, {comment, Comment}]).

test_latin1_archive(DataDir) ->
    Archive = filename:join(DataDir, "zip-latin1.zip"),
    FileName = [246] ++ ".txt",
    ArchiveComment = [246],
    zip_check(Archive, ArchiveComment, FileName, "").

test_zip_dir(Config) when is_list(Config) ->
    case {os:find_executable("unzip"), os:type()} of
        {UnzipPath, {unix,_}} when is_list(UnzipPath)->
            DataDir = get_value(data_dir, Config),
            Dir = filename:join([DataDir, "test-zip", "dir-1"]),
            TestZipOutputDir = filename:join(DataDir, "test-zip-output"),
            TestZipOutput = filename:join(TestZipOutputDir, "test.zip"),
            zip:create(TestZipOutput, [Dir]),
            run_command(UnzipPath, ["-o", TestZipOutput,  "-d", TestZipOutputDir]),
            {ok, FileContent} = file:read_file(filename:join([TestZipOutputDir, Dir, "file.txt"])),
            <<"OKOK\n">> = FileContent,
            ok;
        _ -> {skip, "Not Unix or unzip program not found"}
    end.

run_command(Command, Args) ->
    Port = erlang:open_port({spawn_executable, Command}, [{args, Args}, exit_status]),
    (fun Reciver() ->
             receive
                 {Port,{exit_status,_}} -> ok;
                 {Port, S} -> io:format("UNZIP: ~p~n", [S]),
                              Reciver()
             end
     end)().
    
explicit_file_info(_Config) ->
    Epoch = {{1980,1,1},{0,0,0}},
    FileInfo = #file_info{type=regular, size=0, mtime=Epoch},
    Files = [{"datetime", <<>>, FileInfo},
             {"seconds", <<>>, FileInfo#file_info{mtime=315532800}}],
    {ok, _} = zip:zip("", Files, [memory]),
    ok.

mode(Config) ->

    PrivDir = get_value(pdir, Config),
    ExtractDir = filename:join(PrivDir, "extract"),
    Archive = filename:join(PrivDir, "archive.zip"),

    Executable = filename:join(PrivDir,"exec"),
    file:write_file(Executable, "aaa"),
    {ok, ExecFI } = file:read_file_info(Executable),
    ok = file:write_file_info(Executable, ExecFI#file_info{ mode = 8#111 bor 8#400 }),
    {ok, #file_info{ mode = OrigExecMode }} = file:read_file_info(Executable),

    Directory = filename:join(PrivDir,"dir"),
    ok = file:make_dir(Directory),
    {ok, DirFI } = file:read_file_info(Directory),

    NestedFile = filename:join(Directory, "nested"),
    file:write_file(NestedFile, "bbb"),
    {ok, NestedFI } = file:read_file_info(NestedFile),

    ok = file:write_file_info(Directory, DirFI#file_info{ mode = 8#111 bor 8#400 }),
    {ok, #file_info{ mode = OrigDirMode }} = file:read_file_info(Directory),

    ?assertMatch(
       {ok, Archive},
       zip(Config, Archive, "-r", ["dir","exec"], [{cwd, PrivDir},{extra,[extended_timestamp]}])),

    OrigExecMode777 = OrigExecMode band 8#777,
    OrigDirMode777 = OrigDirMode band 8#777,
    OrigNestedFileMode777 = NestedFI#file_info.mode band 8#777,

    ?assertMatch(
       {ok, [#zip_comment{},
             #zip_file{ name = "dir/", info = #file_info{ mode = OrigDirMode777 }},
             #zip_file{ name = "dir/nested", info = #file_info{ mode = OrigNestedFileMode777 }},
             #zip_file{ name = "exec", info = #file_info{ mode = OrigExecMode777 }} ]},
       zip:list_dir(Archive)),

    ok = file:make_dir(ExtractDir),
    ?assertMatch(
       {ok, ["dir/","dir/nested","exec"]}, unzip(Config, Archive, [{cwd,ExtractDir}])),

    case un_z64(get_value(unzip, Config)) =/= unemzip of
        true ->
            {ok,#file_info{ mode = ExecMode }} =
                file:read_file_info(filename:join(ExtractDir,"exec")),
            ?assertEqual(ExecMode band 8#777, OrigExecMode777),

            {ok,#file_info{ mode = DirMode }} =
                file:read_file_info(filename:join(ExtractDir,"dir")),
            ?assertEqual(DirMode band 8#777, OrigDirMode777),

            {ok,#file_info{ mode = NestedMode }} =
                file:read_file_info(filename:join(ExtractDir,"dir/nested")),
            ?assertEqual(NestedMode band 8#777, OrigNestedFileMode777);
        false ->
            %% emzip does not support mode
            ok
    end,

    ok.

%% Test that zip64 local and central headers are respected when unzipping.
%% The fields in the header that can be 64-bit are:
%%  * compressed size
%%  * uncompressed size
%%  * relative offset
%%  * starting disk
%%
%% As we do not support using multiple disks, we do not test starting disks
zip64_central_headers() -> [{timetrap, {minutes, 60}}].
zip64_central_headers(Config) ->

    PrivDir = get_value(pdir, Config),
    Archive = filename:join(PrivDir, "../archive.zip"),

    %% Check that ../../large.txt exists and is of correct size
    {ok, #file_info{ size = 1 bsl 32 } } =
        file:read_file_info(filename:join(PrivDir, "../../large.txt")),

    %% We very carefully create an archive that should contain all
    %% different header combinations.
    %% - uncomp.txt: uncomp size > 4GB
    %% - uncomp.comp.zip: uncomp and comp size > 4GB
    %% - offset.txt: offset > 4GB
    %% - uncomp.offset.txt: uncomp size and offset > 4GB
    %% - uncomp.comp.offset.zip: uncomp and comp size and offset > 4GB
    %%
    %% The archive will be roughly 8 GBs large

    ok = file:make_link(filename:join(PrivDir, "../../large.txt"),
                        filename:join(PrivDir, "uncomp.txt")),
    ok = file:make_link(filename:join(PrivDir, "../../large.txt"),
                        filename:join(PrivDir, "uncomp.comp.zip")),
    ok = file:make_link(filename:join(PrivDir, "../../medium.txt"),
                        filename:join(PrivDir, "offset.txt")),
    ok = file:make_link(filename:join(PrivDir, "../../large.txt"),
                        filename:join(PrivDir, "uncomp.offset.txt")),
    ok = file:make_link(filename:join(PrivDir, "../../large.txt"),
                        filename:join(PrivDir, "uncomp.comp.offset.zip")),
    ?assertMatch(
       {ok, Archive},
       zip(Config, Archive, "-1",
           ["uncomp.txt","uncomp.comp.zip","offset.txt",
            "uncomp.offset.txt","uncomp.comp.offset.zip"],
           [{cwd, PrivDir}])),

    %% Check that list archive works
    {ok, [#zip_comment{},
          #zip_file{ name = "uncomp.txt",
                     info = #file_info{ size = 1 bsl 32 } },
          #zip_file{ name = "uncomp.comp.zip",
                     comp_size = 1 bsl 32,
                     info = #file_info{ size = 1 bsl 32 } },
          #zip_file{ name = "offset.txt",
                     info = #file_info{ size = 4 bsl 20 } },
          #zip_file{ name = "uncomp.offset.txt",
                     info = #file_info{ size = 1 bsl 32 } },
          #zip_file{ name = "uncomp.comp.offset.zip",
                     comp_size = 1 bsl 32,
                     info = #file_info{ size = 1 bsl 32 } }
         ]} =
        zip:list_dir(Archive),
    ok.

unzip64_central_headers() -> [{timetrap, {minutes, 60}}].
unzip64_central_headers(Config) ->

    PrivDir = get_value(pdir, Config),
    ExtractDir = filename:join(PrivDir, "extract"),
    Archive = filename:join(PrivDir, "../../archive.zip"),
    Large4GB = filename:join(get_value(priv_dir, Config),"large.txt"),
    Medium4MB = filename:join(get_value(priv_dir, Config), "medium.txt"),

    %% Test that extraction of each file works
    lists:map(
      fun F({Name, Compare}) ->
              ok = file:make_dir(ExtractDir),
              ?assertMatch(
                 {ok, [Name]},
                 unzip(Config, Archive, [{cwd, ExtractDir},{file_list,[Name]}])),
              cmp(Compare, filename:join(ExtractDir,Name)),
              file:del_dir_r(ExtractDir);
          F(Name) ->
              F({Name, Large4GB})
      end, ["uncomp.txt","uncomp.comp.zip",{"offset.txt",Medium4MB},
            "uncomp.offset.txt","uncomp.comp.offset.zip"]),

    ok.

%% Test that zip64 end of central directory are respected when unzipping.
%% The fields in the header that can be 64-bit are:
%%   * total number of files > 2 bytes
%%   * size of central directory > 4 bytes (cannot test as it requires an archive with 8 million files)
%%   * offset of central directory > 4 bytes (implicitly tested when testing large relative location of header)
%%
%% Fields that we don't test as we don't support multiple disks
%%   * number of disk where end of central directory is > 2 bytes
%%   * number of disk to find central directory > 2 bytes
%%   * number central directory entries on this disk > 2 bytes
zip64_central_directory(Config) ->

    PrivDir = get_value(pdir, Config),
    Dir = filename:join(PrivDir, "files"),
    ExtractDir = filename:join(PrivDir, "extract"),

    Archive = filename:join(PrivDir, "archive.zip"),

    %% To test when total number of files > 65535, we create an archive with 66000 entries
    ok = file:make_dir(Dir),
    lists:foreach(
      fun(I) ->
              ok = file:write_file(filename:join(Dir, integer_to_list(I)++".txt"),<<0:8>>)
      end, lists:seq(0, 65600)),
    ?assertMatch(
       {ok, Archive},
       zip(Config, Archive, "-1 -r", ["files"], [{cwd, PrivDir}])),

    {ok, Files} = zip:list_dir(Archive),
    ?assertEqual(65603, length(Files)),

    ok = file:make_dir(ExtractDir),
    ?assertMatch(
       {ok, ["files/1.txt","files/65599.txt"]},
       unzip(Config, Archive, [{cwd, ExtractDir},{file_list,["files/1.txt",
                                                             "files/65599.txt"]}])),
    cmp(filename:join(ExtractDir,"files/1.txt"),
        filename:join(ExtractDir,"files/65599.txt")),

    ok.

%% Test basic timestamps, the atime and mtime should be the original
%% mtime of the file
basic_timestamp(Config) ->
    PrivDir =  get_value(pdir, Config),
    Archive = filename:join(PrivDir, "archive.zip"),
    ExtractDir = filename:join(PrivDir, "extract"),
    Testfile = filename:join(PrivDir, "testfile.txt"),

    ok = file:write_file(Testfile, "abc"),
    {ok, OndiskFI = #file_info{ mtime = Mtime }} =
        file:read_file_info(Testfile),

    %% Sleep a bit to let the timestamp progress
    timer:sleep(1000),

    %% Create an archive without extended timestamps
    ?assertMatch(
       {ok, Archive},
       zip(Config, Archive, "-X", ["testfile.txt"], [{cwd, PrivDir}, {extra, []}])),

    {ok, [#zip_comment{},
          #zip_file{ info = ZipFI = #file_info{ mtime = ZMtime }} ]} =
        zip:list_dir(Archive),

    ct:log("on disk: ~p",[OndiskFI]),
    ct:log("in zip : ~p",[ZipFI]),
    ct:log("zipinfo:~n~ts",[os:cmd("zipinfo -v "++Archive)]),

    %% Timestamp in archive is when entry was added to archive
    %% Need to add 2 to ZMtime as the dos time in zip archives
    %% are in precise.
    ?assert(calendar:datetime_to_gregorian_seconds(Mtime) =<
                calendar:datetime_to_gregorian_seconds(ZMtime) + 1),

    %% Sleep a bit to let the timestamp progress
    timer:sleep(1000),

    ok = file:make_dir(ExtractDir),
    ?assertMatch(
       {ok, ["testfile.txt"]},
       unzip(Config, Archive, [{cwd,ExtractDir}])),

    {ok, UnzipFI } =
        file:read_file_info(filename:join(ExtractDir, "testfile.txt"),[raw]),


    ct:log("extract: ~p",[UnzipFI]),

    UnzipMode = un_z64(get_value(unzip, Config)),

    assert_timestamp(UnzipMode, UnzipFI, ZMtime),

    ok.

%% Test extended timestamps, the atime and ctime in the archive are
%% the atime and ctime when the file is added to the archive.
extended_timestamp(Config) ->

    PrivDir =  get_value(pdir, Config),
    Archive = filename:join(PrivDir, "archive.zip"),
    ExtractDir = filename:join(PrivDir, "extract"),
    Testfile = filename:join(PrivDir, "testfile.txt"),

    ok = file:write_file(Testfile, "abc"),
    {ok, OndiskFI = #file_info{ mtime = Mtime }} =
        file:read_file_info(Testfile),

    %% Sleep a bit to let the timestamp progress
    timer:sleep(1000),

    ?assertMatch(
       {ok, Archive},
       zip(Config, Archive, "", ["testfile.txt"], [{cwd, PrivDir}])),

    %% list_dir only reads the central directory header and thus only
    %% the mtime will be correct here
    {ok, [#zip_comment{},
          #zip_file{ info = ZipFI = #file_info{ mtime = ZMtime}} ]} =
        zip:list_dir(Archive),

    ct:log("on disk: ~p",[OndiskFI]),
    ct:log("in zip : ~p",[ZipFI]),
    ct:log("zipinfo:~n~ts",[os:cmd("zipinfo -v "++Archive)]),

    ?assertEqual(Mtime, ZMtime),

    %% Sleep a bit to let the timestamp progress
    timer:sleep(1000),

    ok = file:make_dir(ExtractDir),
    ?assertMatch(
       {ok, ["testfile.txt"]},
       unzip(Config, Archive, [{cwd,ExtractDir}])),

    {ok, UnzipFI } =
        file:read_file_info(filename:join(ExtractDir, "testfile.txt"),[raw]),

    ct:log("extract: ~p",[UnzipFI]),

    UnzipMode = un_z64(get_value(unzip, Config)),

    assert_timestamp(UnzipMode, UnzipFI, ZMtime ),

    ok.

% checks that the timestamps in the zip file are wrapped if > 59
capped_timestamp(Config) ->

    DataDir = get_value(data_dir, Config),
    Archive = filename:join(DataDir, "bad_seconds.zip"),
    PrivDir =  get_value(pdir, Config),
    ExtractDir = filename:join(PrivDir, "extract"),

    {ok, [#zip_comment{},
          #zip_file{ info = ZipFI = #file_info{ mtime = ZMtime }} ]} =
        zip:list_dir(Archive),

    ct:log("in zip : ~p",[ZipFI]),

    %% zipinfo shows something different from what unzip
    ct:log("zipinfo:~n~ts",[os:cmd("zipinfo -v "++Archive)]),

    % and not {{2024, 12, 31}, {23, 59, 60}}
    ?assertEqual({{2025, 1, 1}, {0, 0, 0}}, ZMtime),

    ok = file:make_dir(ExtractDir),
    ?assertMatch(
       {ok, ["testfile.txt"]},
       unzip(Config, Archive, [{cwd,ExtractDir}])),

    {ok, UnzipFI } =
        file:read_file_info(filename:join(ExtractDir, "testfile.txt"),[raw]),

    ct:log("extract: ~p",[UnzipFI]),
    UnzipMode = un_z64(get_value(unzip, Config)),
    assert_timestamp(UnzipMode, UnzipFI, ZMtime),
    ok.

assert_timestamp(unemzip, _FI, _ZMtime) ->
    %% emzip does not support timestamps
    ok;
assert_timestamp(_, #file_info{ atime = UnZAtime, mtime = UnZMtime, ctime = UnZCtime }, ZMtime) ->

    ?assertEqual(ZMtime, UnZMtime),

    %% both atime and ctime behave very differently on different platforms, so it is rather hard to test.
    %% atime is sometimes set to ctime for unknown reasons, and sometimes set to 1970...
    ?assert(UnZAtime =:= UnZMtime orelse UnZAtime =:= UnZCtime orelse UnZAtime =:= {{1970,1,1},{1,0,0}}),

    %% On windows the ctime and mtime are the same so
    %% we cannot compare them.
    [?assert(UnZMtime < UnZCtime) || os:type() =/= {win32,nt}],

    ok.

uid_gid(Config) ->

    PrivDir = get_value(pdir, Config),
    ExtractDir = filename:join(PrivDir, "extract"),
    Archive = filename:join(PrivDir, "archive.zip"),
    Testfile = filename:join(PrivDir, "testfile.txt"),

    ok = file:write_file(Testfile, "abc"),
    {ok, OndiskFI = #file_info{ gid = GID, uid = UID }} =
        file:read_file_info(Testfile),

    ?assertMatch(
       {ok, Archive},
       zip(Config, Archive, "", ["testfile.txt"], [{cwd, PrivDir}])),

    {ok, [#zip_comment{},
          #zip_file{ info = ZipFI = #file_info{ gid = ZGID, uid = ZUID }} ]} =
        zip:list_dir(Archive,[{extra, [uid_gid]}]),

    ct:log("on disk: ~p",[OndiskFI]),
    ct:log("in zip : ~p",[ZipFI]),

    ?assertEqual(UID, ZUID),
    ?assertEqual(GID, ZGID),

    ok = file:make_dir(ExtractDir),
    ?assertMatch(
       {ok, ["testfile.txt"]},
       unzip(Config, Archive, [{cwd, ExtractDir},{extra,[uid_gid]}])),

    {ok,#file_info{ gid = ExZGID, uid = ExZUID }} =
        file:read_file_info(filename:join(ExtractDir,"testfile.txt")),

    case un_z64(get_value(unzip, Config)) =/= unemzip of
        true ->
            ?assertEqual(UID, ExZUID),
            ?assertEqual(GID, ExZGID);
        _ ->
            %% emzip does not support uid_gid
            ok
    end,

    ok.

sanitize_filenames(Config) ->
    RootDir = get_value(pdir, Config),
    TempDir = filename:join(RootDir, "sanitize_filenames"),
    ok = file:make_dir(TempDir),

    %% Check that /tmp/absolute does not exist
    {error, enoent} = file:read_file("/tmp/absolute"),

    %% Create a zip archive /tmp/absolute in it
    %%   This file was created using the command below on Erlang/OTP 28.0
    %%   1> rr(file), {ok, {_, Bin}} = zip:zip("absolute.zip", [{"/tmp/absolute",<<>>,#file_info{ type=regular, mtime={{2000,1,1},{0,0,0}}, size=0 }}], [memory]), rp(base64:encode(Bin)).
    AbsZip = base64:decode(<<"UEsDBAoAAAAAAAAAISgAAAAAAAAAAAAAAAANAAkAL3RtcC9hYnNvbHV0ZVVUBQABcDVtOFBLAQI9AwoAAAAAAAAAISgAAAAAAAAAAAAAAAANAAkAAAAAAAAAAACkAQAAAAAvdG1wL2Fic29sdXRlVVQFAAFwNW04UEsFBgAAAAABAAEARAAAADQAAAAAAA==">>),
    AbsArchive = filename:join(TempDir, "absolute.zip"),
    ok = file:write_file(AbsArchive, AbsZip),

    {ok, ["tmp/absolute"]} = unzip(Config, AbsArchive, [verbose, {cwd, TempDir}]),

    zipinfo_match(AbsArchive, "/tmp/absolute"),

    case un_z64(get_value(unzip, Config)) =/= unemzip of
        true ->
            {error, enoent} = file:read_file("/tmp/absolute"),
            {ok, <<>>} = file:read_file(filename:join([TempDir, "tmp", "absolute"]));
        false ->
            ok
    end,

    RelArchive = filename:join(TempDir, "relative.zip"),
    Relative = filename:join(TempDir, "relative"),
    ok = file:write_file(Relative, <<>>),
    ?assertMatch({ok, RelArchive},zip(Config, RelArchive, "", [Relative], [{cwd, TempDir}])),

    SanitizedRelative = filename:join(tl(filename:split(Relative))),
    case un_z64(get_value(unzip, Config)) =:= unemzip of
        true ->
            {ok, [SanitizedRelative]} = unzip(Config, RelArchive, [{cwd, TempDir}]);
        false ->
            ok
    end,

    zipinfo_match(RelArchive, SanitizedRelative),

    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Generic zip interface
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
zip(Config, Archive, ZipOpts, Filelist, Opts) when is_list(Config) ->
    zip(get_value(zip, Config),
        Archive, ZipOpts, Filelist, Opts);
zip(z64_zip, Archive, ZipOpts, Filelist, Opts) ->
    zip(zip, Archive, ZipOpts, Filelist, Opts);
zip(zip, Archive, ZipOpts, Filelist, Opts) ->
    cmd("cd "++get_value(cwd, Opts)++" && "
        "zip "++ZipOpts++" "++Archive++" "++lists:join($ ,Filelist)),
    {ok, Archive};
zip(z64_ezip, Archive, _ZipOpts, Filelist, Opts) ->
    zip(ezip, Archive, _ZipOpts, Filelist, Opts);
zip(ezip, Archive, _ZipOpts, Filelist, Opts) ->
    ct:log("Creating zip:zip(~p,~n~p,~n~p)",[Archive, Filelist, Opts]),
    zip:zip(Archive, Filelist, Opts);
zip(z64_emzip, Archive, _ZipOpts, Filelist, Opts) ->
    %% Run in peer node so that memory issues don't crash test node
    {ok, Peer, Node} = ?CT_PEER(#{ args => emzip_peer_args() }),
    try
        erpc:call(
          Node,
          fun() ->
            ?MODULE:zip(emzip, Archive, _ZipOpts, Filelist, Opts)
          end)
    after
        catch peer:stop(Peer)
    end;
zip(emzip, Archive, _ZipOpts, Filelist, Opts) ->
    ct:log("Creating emzip ~ts",[Archive]),
    Cwd = get_value(cwd, Opts),

    
    %% For this not to use a huge amount of memory we re-use
    %% the binary for files that are the same size as those are the same file.
    %% This cuts memory usage from ~16GB to ~4GB.

    {Files,_Cache} =
        lists:mapfoldl(
        fun F(Fn, Cache) ->
                AbsFn = filename:join(Cwd, Fn),
                {ok, Fi} = file:read_file_info(AbsFn),
                CacheKey = {Fi#file_info.type, Fi#file_info.size},
                {SubDirFiles, NewCache} =
                    if Fi#file_info.type == directory ->
                            {ok, Files} = file:list_dir(AbsFn),
                            lists:mapfoldl(F, Cache#{ CacheKey => <<>> },
                                            [filename:join(Fn, DirFn) || DirFn <- Files]);
                        Fi#file_info.type == regular ->
                            {[],
                                case maps:find(CacheKey, Cache) of
                                    {ok, _} -> Cache;
                                    error ->
                                        {ok, Data} = read_file(
                                                    file:open(AbsFn, [read, raw, binary]),
                                                    Fi#file_info.size),
                                        Cache#{ CacheKey => Data }
                                end}
                    end,
                {[{Fn, maps:get(CacheKey, NewCache), Fi}|SubDirFiles], NewCache}
        end,  #{}, Filelist),
    zip:zip(Archive, lists:flatten(Files), proplists:delete(cwd,Opts)).

%% Special read_file that works on windows on > 4 GB files
read_file({ok, D}, Size) ->
    Bin = iolist_to_binary(read_file(D, Size)),
    erlang:garbage_collect(), %% Do a GC to get rid of all intermediate binaries
    {ok, Bin};
read_file({error, _} = E, _Size) ->
    E;
read_file(eof = E, _Size) ->
    E;
read_file(D, 0) ->
    file:close(D),
    [];
read_file(D, Size) ->
    {ok, B} = file:read(D, min(1 bsl 30, Size)),
    [B | read_file(D, Size - byte_size(B))].

unzip(Config, Archive, Opts) when is_list(Config) ->
    unzip(get_value(unzip, Config), Archive, Opts);
unzip(z64_unzip, Archive, Opts) ->
    unzip(unzip, Archive, Opts);
unzip(unzip, Archive, Opts) ->
    UidGid = [" -X " || lists:member(uid_gid, get_value(extra, Opts, []))],
    Files = lists:join($ , get_value(file_list, Opts, [])),
    Res = cmd("cd "++get_value(cwd, Opts)++" && "
              "unzip "++UidGid++" "++Archive++" "++Files),
    {ok, lists:sort(
           lists:flatmap(
             fun(Ln) ->
                     case re:run(Ln, ~B'\s+[a-z]+: ([^\s]+)', [{capture,all_but_first,list},unicode]) of
                         nomatch -> [];
                         {match,Match} -> Match
                     end
             end,string:split(Res,"\n",all)))};
unzip(z64_unezip, Archive, Opts) ->
    unzip(unezip, Archive, Opts);
unzip(unezip, Archive, Opts) ->
    Cwd = get_value(cwd, Opts) ++ "/",
    {ok, Files} = zip:unzip(Archive, Opts),
    {ok, lists:sort([F -- Cwd || F <- Files])};
unzip(z64_unemzip, Archive, Opts) ->
    %% Run in peer node so that memory issues don't crash test node
    {ok, Peer, Node} = ?CT_PEER(#{ args => emzip_peer_args() }),
    try
      erpc:call(
        Node,
        fun() ->
            unzip(unemzip, Archive, Opts)
        end)
    after
        catch peer:stop(Peer)
    end;
unzip(unemzip, Archive, Opts) ->
    Cwd = get_value(cwd, Opts) ++ "/",
    
    {ok, Files} = zip:unzip(Archive, [memory | Opts]),
    {ok, lists:sort(
            [begin
                case lists:last(F) of
                    $/ ->
                        filelib:ensure_path(F);
                    _ ->
                        filelib:ensure_dir(F),
                        file:write_file(F, B)
                end,
                F -- Cwd
            end || {F, B} <- Files])}.

emzip_peer_args() ->
    8 = erlang:system_info(wordsize),%% Supercarrier only supported on 64-bit
    ["+MMscs",integer_to_list(?EMZIP64_MEM_USAGE div (1024 * 1024))].

cmp(Source, Target) ->
    {ok, SrcInfo} = file:read_file_info(Source),
    {ok, TgtInfo} = file:read_file_info(Target),
    ?assertEqual(SrcInfo#file_info.size, TgtInfo#file_info.size),
    ?assertEqual(SrcInfo#file_info.mode, TgtInfo#file_info.mode),

    {ok, Src} = file:open(Source, [read, binary]),
    {ok, Tgt} = file:open(Target, [read, binary]),

    cmp(Src, Tgt, 0),

    file:close(Src),
    file:close(Tgt).

%% Check if first 100 MB are the same
cmp(Src, Tgt, Pos) when Pos < 100 bsl 20 ->
    erlang:garbage_collect(),
    case {file:read(Src, 20 bsl 20), file:read(Tgt, 20 bsl 20)} of
        {{ok, Data}, {ok, Data}} ->
            cmp(Src, Tgt, Pos + 20 bsl 20);
        {E, E} ->
            ok
    end;
cmp(_Src, _Tgt, _) ->
    ok.

cmd(Cmd) ->
    Res = os:cmd(Cmd),
    ct:log("Cmd: ~ts~nRes: ~ts~n",[Cmd, Res]),
    Res.

disc_free(Path) ->
    Data = disksup:get_disk_data(),

    %% What partitions could Data be mounted on?
    Partitions =
        [D || {P, _Tot, _Perc}=D <- Data,
         lists:prefix(filename:nativename(P), filename:nativename(Path))],

    %% Sorting in descending order places the partition with the most specific
    %% path first.
    case lists:sort(fun erlang:'>='/2, Partitions) of
        [{_,Tot, Perc} | _] -> round(Tot * (1-(Perc/100)));
        [] -> error
    end.

memsize() ->
    case proplists:get_value(available_memory, memsup:get_system_memory_data()) of
        undefined ->
            {Tot,_Used,_}  = memsup:get_memory_data(),
            Tot;
        Available ->
            Available
    end.
