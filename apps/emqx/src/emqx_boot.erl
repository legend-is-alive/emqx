%%--------------------------------------------------------------------
%% Copyright (c) 2017-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%--------------------------------------------------------------------

-module(emqx_boot).

-export([is_enabled/1]).

-define(BOOT_MODULES, [router, broker, listeners]).

-spec is_enabled(all | router | broker | listeners) -> boolean().
is_enabled(Mod) ->
    (BootMods = boot_modules()) =:= all orelse lists:member(Mod, BootMods).

boot_modules() ->
    application:get_env(emqx, boot_modules, ?BOOT_MODULES).
