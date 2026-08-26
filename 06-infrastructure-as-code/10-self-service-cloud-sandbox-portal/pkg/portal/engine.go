package portal

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
)

// Engine executes Terraform / OpenTofu operations for sandboxes.
type Engine struct {
	iacBinary    string
	templatesDir string
	workspacesDir string
	logsDir      string
}

// NewEngine initializes the IaC execution engine.
func NewEngine(templatesDir, workspacesDir, logsDir string) (*Engine, error) {
	binary := "tofu"
	if _, err := exec.LookPath(binary); err != nil {
		binary = "terraform"
		if _, err := exec.LookPath(binary); err != nil {
			return nil, fmt.Errorf("neither 'tofu' nor 'terraform' found in PATH")
		}
	}

	if err := os.MkdirAll(workspacesDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create workspaces dir: %w", err)
	}
	if err := os.MkdirAll(logsDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create logs dir: %w", err)
	}

	return &Engine{
		iacBinary:     binary,
		templatesDir:  templatesDir,
		workspacesDir: workspacesDir,
		logsDir:       logsDir,
	}, nil
}

// ProvisionSandbox creates the workspace, copies templates, and executes terraform apply.
func (e *Engine) ProvisionSandbox(ctx context.Context, sbx *Sandbox, params map[string]interface{}) error {
	workspaceDir := filepath.Join(e.workspacesDir, sbx.ID)
	logFile := filepath.Join(e.logsDir, fmt.Sprintf("%s.log", sbx.ID))

	sbx.WorkspaceDir = workspaceDir
	sbx.LogFile = logFile

	// 1. Validate template exists
	tmplDir := filepath.Join(e.templatesDir, sbx.Template)
	if _, err := os.Stat(tmplDir); os.IsNotExist(err) {
		return fmt.Errorf("template '%s' not found under %s", sbx.Template, e.templatesDir)
	}

	// 2. Create workspace directory and copy template files
	if err := copyDirectory(tmplDir, workspaceDir); err != nil {
		return fmt.Errorf("failed to initialize sandbox workspace: %w", err)
	}

	// 3. Write variables to terraform.tfvars.json
	tfVars := map[string]interface{}{
		"sandbox_id":      sbx.ID,
		"developer_email": sbx.DeveloperEmail,
	}
	for k, v := range params {
		tfVars[k] = v
	}

	varsBytes, err := json.MarshalIndent(tfVars, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to serialize variables: %w", err)
	}
	if err := os.WriteFile(filepath.Join(workspaceDir, "terraform.tfvars.json"), varsBytes, 0644); err != nil {
		return fmt.Errorf("failed to write terraform.tfvars.json: %w", err)
	}

	// Open log file
	logF, err := os.OpenFile(logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return fmt.Errorf("failed to open log file: %w", err)
	}
	defer logF.Close()

	// 4. Run terraform init
	initCmd := exec.CommandContext(ctx, e.iacBinary, "init", "-no-color")
	initCmd.Dir = workspaceDir
	initCmd.Stdout = logF
	initCmd.Stderr = logF
	if err := initCmd.Run(); err != nil {
		return fmt.Errorf("terraform init failed: %w (see %s)", err, logFile)
	}

	// 5. Run terraform apply
	applyCmd := exec.CommandContext(ctx, e.iacBinary, "apply", "-auto-approve", "-no-color")
	applyCmd.Dir = workspaceDir
	applyCmd.Stdout = logF
	applyCmd.Stderr = logF
	if err := applyCmd.Run(); err != nil {
		return fmt.Errorf("terraform apply failed: %w (see %s)", err, logFile)
	}

	// 6. Extract outputs
	outputCmd := exec.CommandContext(ctx, e.iacBinary, "output", "-json")
	outputCmd.Dir = workspaceDir
	outBytes, err := outputCmd.Output()
	if err == nil {
		var rawOutputs map[string]struct {
			Value interface{} `json:"value"`
		}
		if err := json.Unmarshal(outBytes, &rawOutputs); err == nil {
			parsed := make(map[string]interface{})
			for k, v := range rawOutputs {
				parsed[k] = v.Value
			}
			sbx.Outputs = parsed
		}
	}

	return nil
}

// DestroySandbox runs terraform destroy in the sandbox workspace.
func (e *Engine) DestroySandbox(ctx context.Context, sbx *Sandbox) error {
	if sbx.WorkspaceDir == "" {
		return nil
	}

	logF, err := os.OpenFile(sbx.LogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err == nil {
		defer logF.Close()
	}

	destroyCmd := exec.CommandContext(ctx, e.iacBinary, "destroy", "-auto-approve", "-no-color")
	destroyCmd.Dir = sbx.WorkspaceDir
	if logF != nil {
		destroyCmd.Stdout = logF
		destroyCmd.Stderr = logF
	}

	return destroyCmd.Run()
}

func copyDirectory(src, dst string) error {
	if err := os.MkdirAll(dst, 0755); err != nil {
		return err
	}

	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}

	for _, entry := range entries {
		srcPath := filepath.Join(src, entry.Name())
		dstPath := filepath.Join(dst, entry.Name())

		if entry.IsDir() {
			if entry.Name() == ".terraform" {
				continue
			}
			if err := copyDirectory(srcPath, dstPath); err != nil {
				return err
			}
		} else {
			if err := copyFile(srcPath, dstPath); err != nil {
				return err
			}
		}
	}
	return nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}
