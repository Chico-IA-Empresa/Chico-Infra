"""Run selected existing worker tests under ARM64 with bounded mock providers."""
from pathlib import Path
import os
import sys

for wheel in Path('/checks/wheels').glob('*.whl'):
    sys.path.insert(0, str(wheel))
os.environ['PYTEST_DISABLE_PLUGIN_AUTOLOAD'] = '1'

import pytest

if __name__ == '__main__':
    # Root backend conftest is never mounted: only the PG16 transaction fixture
    # under /suite is loaded. Existing test bodies execute without modification.
    sys.exit(pytest.main(['/suite', '--confcutdir=/suite', '-p', 'pytest_asyncio.plugin',
                         '-o', 'asyncio_mode=auto', '-q', '--tb=short', '--disable-warnings']))
