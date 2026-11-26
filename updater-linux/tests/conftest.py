import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import platform

import pytest

import fixtures

pytestmark_x86 = pytest.mark.skipif(platform.machine() != "x86_64", reason="fixture AppImage is an x86-64 ELF")


@pytest.fixture
def env(tmp_path):
    e = fixtures.Env(tmp_path)
    yield e
    e.close()
