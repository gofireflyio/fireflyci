# FireflyCI for GitHub Actions

FireflyCI is a command line interface for the FireflyCI Firefly actions

### The plan step must output into a file
```yaml
- name: Terraform Plan
  id: plan
  run: |
    terraform plan -json -out=plan.tmp > plan_log.jsonl && terraform show -json plan.tmp > plan_output.json
  continue-on-error: true
```

### FireflyCI Post-Plan
```yaml
- name: FireflyCI Post-Plan
  uses: gofireflyio/fireflyci@v0.2.9
  with:
    command: post-plan
    plan-output-file: plan_output.json
    plan-log-file: plan_log.jsonl
    workspace: <WORKSPACE_NAME>
    context: <WORKING_DIR>
  env:
    FIREFLY_ACCESS_KEY: ${{ secrets.FIREFLY_ACCESS_KEY }}
    FIREFLY_SECRET_KEY: ${{ secrets.FIREFLY_SECRET_KEY }}
```

### The apply must output into a file
```yaml
- name: Terraform Apply
  id: apply
  run: terraform apply -auto-approve -json > apply_log.jsonl
  continue-on-error: true
```

### FireflyCI Post-Apply
```yaml
- name: FireflyCI Post-Apply
  uses: gofireflyio/fireflyci@v0.2.9
  with:
    command: post-apply
    apply-log-file: apply.jsonl
    workspace: <WORKSPACE_NAME>
    context: <WORKING_DIR>
  env:
    FIREFLY_ACCESS_KEY: ${{ secrets.FIREFLY_ACCESS_KEY }}
    FIREFLY_SECRET_KEY: ${{ secrets.FIREFLY_SECRET_KEY }}
```


