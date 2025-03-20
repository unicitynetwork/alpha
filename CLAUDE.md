# Alpha Project Guidelines

## Build Commands
- Basic build: `./autogen.sh && ./configure && make`
- With GUI: `./autogen.sh && make -C depends && ./configure --prefix=$PWD/depends/x86_64-pc-linux-gnu --program-transform-name='s/bitcoin/alpha/g' && make && make install`
- Without GUI: `./autogen.sh && make -C depends NO_QT=1 && ./configure --without-gui --prefix=$PWD/depends/x86_64-pc-linux-gnu --program-transform-name='s/bitcoin/alpha/g' && make && make install`
- Debug build: `./configure --enable-debug && make`

## Test Commands
- All unit tests: `make check`
- Single unit test: `src/test/test_bitcoin --run_test=getarg_tests/doubledash`
- All functional tests: `test/functional/test_runner.py`
- Single functional test: `test/functional/feature_rbf.py`
- Test coverage: `./configure --enable-lcov && make && make cov`

## Lint Commands
- Run all lint checks: `ci/lint_run_all.sh`
- Run clang-tidy: `bear --config src/.bear-tidy-config -- make -j $(nproc) && cd ./src/ && run-clang-tidy -j $(nproc)`

## Code Style
- C++: 4-space indentation, braces on new lines for functions/classes
- Variables: `snake_case`, class members with `m_` prefix, constants in `ALL_CAPS`, globals with `g_` prefix
- Class/methods: `UpperCamelCase` for classes, no `C` prefix
- Commit messages: 50 chars title + blank line + description
- PR titles: Prefix with component (consensus, doc, qt, wallet, etc.)
- Python: Follow PEP-8, use f-strings, include docstrings
- Include guards: `BITCOIN_FOO_BAR_H` format
- Imports: No `using namespace` in global scope
- Error handling: Use `assert`/`Assert` for assumptions, `CHECK_NONFATAL` for recoverable errors
- Use init lists for member initialization: `int x{0};` instead of `int x = 0;`
- Always use full namespace specifiers for function calls