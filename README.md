# FireFlyCI for Github Actions

FireFlyCI is a command line interface for the FireflyCI Firefly actions

### The plan step must output into a file
```yaml
    - name: Terraform Plan
      id: plan
      run: |
        terraform plan -out=plan.tmp
        terraform show -no-color -json plan.tmp > ${GITHUB_WORKSPACE}/plan.json
      continue-on-error: true
```

### FireFlyCI Post-Plan (mention the plan file)
```yaml
- name: FireFlyCI Post-Plan
  uses: gofireflyio/fireflyci@v1.0
  with:
    command: post-plan
    plan-file: plan.json
    workspace: workspace_dir/
    args: --timeout 180
  env:
    FIREFLY_ACCESS_KEY: ${{ secrets.FIREFLY_ACCESS_KEY }}
    FIREFLY_SECRET_KEY: ${{ secrets.FIREFLY_SECRET_KEY }}
```

### The apply step must output into a file
```yaml
    - name: Terraform Apply
      id: apply
      run: terraform apply -no-color -auto-approve -json > ${GITHUB_WORKSPACE}/apply.json
      continue-on-error: true
```

### FireFlyCI Post-Apply (mention the apply file)
```yaml
- name: FireFlyCI Post-Apply
  uses: gofireflyio/fireflyci@v1.0
  with:
    command: post-apply
    apply-file: apply.json
    workspace: workspace_dir/
    args: --timeout 180
  env:
    FIREFLY_ACCESS_KEY: ${{ secrets.FIREFLY_ACCESS_KEY }}
    FIREFLY_SECRET_KEY: ${{ secrets.FIREFLY_SECRET_KEY }}
```


