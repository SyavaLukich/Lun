#!/usr/bin/env python3
"""Запуск тестов мода smart_npc.

Сначала пытается найти обычный интерпретатор Lua (luajit/lua/lua5.1),
иначе использует Python-пакет lupa (pip install lupa). Для lupa
предпочитается LuaJIT 2.1 — тот же движок, что и в Luanti.

Из корня репозитория:
    python3 tests/run_tests.py
"""

import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = [
    "tests/smart_npc_core.lua",
    "tests/smart_npc_engine.lua",
]


def find_lua():
    for name in ("luajit", "lua", "lua5.1", "lua5.4", "lua5.3"):
        path = shutil.which(name)
        if path:
            return path
    return None


def run_with_lua(binary):
    failed = False
    for test in TESTS:
        print("== %s (%s)" % (test, os.path.basename(binary)))
        result = subprocess.run([binary, test], cwd=ROOT)
        if result.returncode != 0:
            failed = True
    return failed


def load_lupa():
    import importlib

    for module_name in ("lupa.luajit21", "lupa.lua51", "lupa.lua54", "lupa.lua55"):
        try:
            return importlib.import_module(module_name)
        except ImportError:
            continue
    try:
        import lupa  # noqa: F401
    except ImportError:
        return None
    return lupa


def run_with_lupa(module):
    os.environ["SMART_NPC_EMBEDDED"] = "1"
    failed = False
    for test in TESTS:
        print("== %s (%s)" % (test, getattr(module, "LUA_VERSION", "lua")))
        lua = module.LuaRuntime(unpack_returned_tuples=True)
        try:
            with open(os.path.join(ROOT, test), encoding="utf-8") as handle:
                lua.execute(handle.read())
        except Exception as error:  # noqa: BLE001
            print("Ошибка выполнения: %s" % error)
            failed = True
            continue
        if getattr(lua.globals(), "SMART_NPC_FAILED", None):
            failed = True
    return failed


def main():
    os.chdir(ROOT)
    lua = find_lua()
    if lua:
        failed = run_with_lua(lua)
    else:
        module = load_lupa()
        if module is None:
            print("Не найден Lua и не установлен lupa. Установите LuaJIT/Lua 5.1\n"
                  "или выполните: pip install lupa", file=sys.stderr)
            return 2
        failed = run_with_lupa(module)
    if failed:
        print("\nЕсть провалившиеся тесты.")
        return 1
    print("\nВсе тесты пройдены.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
