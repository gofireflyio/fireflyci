# Terragrunt IaC Wrapper

A GitHub Action that installs a wrapper script to intercept and log Terraform/OpenTofu commands when invoked by Terragrunt. This enables automatic capture of logs for each module in a Terragrunt stack.

## What It Does

When Terragrunt executes Terraform/OpenTofu across multiple modules, this action ensures that each module's logs are captured separately. The wrapper intercepts commands and creates per-module log files:

- `init_log.jsonl` - Initialization output
- `plan_log.jsonl` - Plan execution logs  
- `plan_output.json` - Plan output in JSON format
- `plan_output_raw.log` - Human-readable plan output
- `apply_log.jsonl` - Apply execution logs
- `destroy_log.jsonl` - Destroy execution logs

## Usage

### Basic Example

```yaml
- name: Setup Terragrunt Wrapper
  uses: gofireflyio/fireflyci/terragrunt
```

### With Options

```yaml
- name: Setup Terragrunt Wrapper  
  uses: gofireflyio/fireflyci/terragrunt
  with:
    iac-binary: 'both'  # Wrap both terraform and tofu
    wrapper-dir: '/opt/iac-wrapper'  # Custom installation directory
```

### Complete Workflow

```yaml
jobs:
  terragrunt-plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.6.0
      
      - name: Setup Terragrunt Wrapper
        uses: gofireflyio/fireflyci/terragrunt
        with:
          iac-binary: 'terraform'
      
      - name: Terragrunt Plan
        run: |
          cd infrastructure
          terragrunt run-all plan -json -out=tfplan
      
      - name: Process Results with FireflyCI
        uses: gofireflyio/fireflyci
        with:
          command: post-plan
          # Logs are automatically captured per module
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `iac-binary` | Which binary to wrap: `terraform`, `tofu`, or `both` | No | `terraform` |
| `wrapper-dir` | Directory to install the wrapper script | No | `/usr/local/bin/iac-wrapper` |

## How It Works

1. **Locates the real IaC binary** - Finds the existing `terraform` or `tofu` installation
2. **Backs up the original** - Moves the real binary to `*.real` (e.g., `terraform.real`)
3. **Installs the wrapper** - Creates a wrapper script that intercepts all commands
4. **Captures logs per module** - When Terragrunt runs across modules, each module's logs are saved to its directory
5. **Preserves exit codes** - All exit codes and errors are properly propagated

## Requirements

- The IaC binary (Terraform or OpenTofu) must be installed before running this action
- Requires `sudo` permissions to move and symlink binaries
- Works on Linux runners (Ubuntu, Debian, etc.)

## Notes

- The wrapper is transparent - it doesn't change how Terragrunt or Terraform behave
- Logs are only captured when using `-json` flags (as per the wrapper script logic)
- The wrapper handles Terragrunt v0.67+ which uses `--` as a separator
- Original binaries are preserved as `*.real` and can be accessed directly if needed

