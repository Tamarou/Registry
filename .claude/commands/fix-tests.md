# Fix Tests Command

Systematic approach to fixing failing tests in the Registry project.

## Process

1. **Run full test suite** to identify current failing tests and get comprehensive failure breakdown:
   ```bash
   carton exec prove -lr t/ --formatter=TAP::Formatter::Console
   ```

2. **Categorize failures by type**:
   - **Missing dependencies**: Can't locate modules (Mojo::Pg, Test::PostgreSQL, etc.)
   - **Database connectivity**: Connection failures, schema issues, migration problems
   - **Compilation failures**: Missing modules, syntax errors, Object::Pad issues
   - **Logic/expectation mismatch**: Tests expecting different behavior than current implementation
   - **Environment issues**: Missing config, wrong paths, permission problems

3. **Start with infrastructure fixes** (highest impact):
   - Install missing system dependencies (PostgreSQL dev libs)
   - Fix carton/cpanfile dependency installation issues
   - Ensure database is properly set up and migrations applied
   - Verify test database configuration

4. **For each remaining failure category**:
   - **Database tests**: Check if `make reset` is needed, verify test DB isolation
   - **DAO tests**: Ensure proper mocking or test database setup
   - **Controller tests**: Check for missing test fixtures or incorrect routing
   - **Workflow tests**: Verify YAML serialization and workflow imports are working
   - **Integration tests**: Check service dependencies and environment setup

5. **For each individual test failure**:
   - Run single test with verbose output: `carton exec prove -lv t/path/to/test.t`
   - Create minimal reproduction case if needed
   - Determine root cause (dependency, database, logic, or environment)
   - Fix incrementally with focused changes
   - Test fix against related test cases

6. **Ensure 100% pass rate** before proceeding to next category

7. **Commit changes** with clear descriptions of what was fixed:
   - "Fix missing dependencies for DAO tests"
   - "Add database setup for workflow tests"
   - "Fix Object::Pad syntax in Payment module"

8. **Run full test suite again** to verify no regressions:
   ```bash
   make test
   ```

9. **Update documentation** to reflect any test environment changes or new requirements

## Registry-Specific Notes

- Use `carton exec` for all test commands to ensure proper local dependencies
- Database tests require PostgreSQL and proper schema deployment
- Workflow tests need YAML files imported: `carton exec ./registry workflow import registry`
- Some tests may need `make reset` to ensure clean database state
- Object::Pad syntax issues are common - check for proper field/method declarations
- Test::PostgreSQL requires DBD::Pg which needs PostgreSQL development libraries

## Quick Commands

```bash
# Run specific test categories
carton exec prove -lr t/dao/
carton exec prove -lr t/controller/
carton exec prove -lr t/workflow/
carton exec prove -lr t/frontend/

# Reset environment
make reset
carton install --deployment

# Check single test with full output
carton exec prove -lv t/dao/payments.t
```