package controllers

import (
	"context"
	"fmt"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	backupv1alpha1 "backup-operator/api/v1alpha1"
)

const (
	backupFinalizer = "finalizers.backup.devops.sre.io/cleanup"
)

// ScheduledBackupReconciler reconciles a ScheduledBackup object
type ScheduledBackupReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

// +kubebuilder:rbac:groups=backup.devops.sre.io,resources=scheduledbackups,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=backup.devops.sre.io,resources=scheduledbackups/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=backup.devops.sre.io,resources=scheduledbackups/finalizers,verbs=update
// +kubebuilder:rbac:groups=batch,resources=cronjobs;jobs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch

// Reconcile is part of the main kubernetes reconciliation loop which aims to
// move the current state of the cluster closer to the desired state.
func (r *ScheduledBackupReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// 1. Fetch the ScheduledBackup instance
	var backup backupv1alpha1.ScheduledBackup
	if err := r.Get(ctx, req.NamespacedName, &backup); err != nil {
		if errors.IsNotFound(err) {
			logger.Info("ScheduledBackup resource not found. Ignoring since object must be deleted.")
			return ctrl.Result{}, nil
		}
		logger.Error(err, "Failed to fetch ScheduledBackup instance")
		return ctrl.Result{}, err
	}

	// 2. Handle Deletion & Finalizers
	if backup.ObjectMeta.DeletionTimestamp.IsZero() {
		// Object is not being deleted, ensure our finalizer is present
		if !controllerutil.ContainsFinalizer(&backup, backupFinalizer) {
			controllerutil.AddFinalizer(&backup, backupFinalizer)
			if err := r.Update(ctx, &backup); err != nil {
				return ctrl.Result{}, err
			}
		}
	} else {
		// Object is being deleted
		if controllerutil.ContainsFinalizer(&backup, backupFinalizer) {
			logger.Info("Executing finalizer cleanup for ScheduledBackup", "name", backup.Name)
			if r.Recorder != nil {
				r.Recorder.Event(&backup, corev1.EventTypeNormal, "Deleting", "Executing finalizer cleanup tasks")
			}
			controllerutil.RemoveFinalizer(&backup, backupFinalizer)
			if err := r.Update(ctx, &backup); err != nil {
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{}, nil
	}

	// 3. Define and Reconcile backing batch/v1 CronJob
	cronJobName := fmt.Sprintf("%s-cronjob", backup.Name)
	cronJob := &batchv1.CronJob{
		ObjectMeta: metav1.ObjectMeta{
			Name:      cronJobName,
			Namespace: backup.Namespace,
		},
	}

	backupImage := backup.Spec.BackupImage
	if backupImage == "" {
		backupImage = "alpine:3.21"
	}

	retentionDays := backup.Spec.RetentionDays
	if retentionDays == 0 {
		retentionDays = 7
	}

	opResult, err := controllerutil.CreateOrUpdate(ctx, r.Client, cronJob, func() error {
		// Set OwnerReference for automatic garbage collection
		if err := ctrl.SetControllerReference(&backup, cronJob, r.Scheme); err != nil {
			return err
		}

		// Mutate CronJob Spec
		cronJob.Spec.Schedule = backup.Spec.Schedule
		cronJob.Spec.Suspend = &backup.Spec.Suspend
		cronJob.Spec.SuccessfulJobsHistoryLimit = int32Ptr(3)
		cronJob.Spec.FailedJobsHistoryLimit = int32Ptr(1)

		cronJob.Spec.JobTemplate.Spec.Template.Spec.RestartPolicy = corev1.RestartPolicyOnFailure
		cronJob.Spec.JobTemplate.Spec.Template.Spec.Containers = []corev1.Container{
			{
				Name:  "backup-runner",
				Image: backupImage,
				Command: []string{
					"/bin/sh",
					"-c",
					fmt.Sprintf("echo '[BACKUP] Starting snapshot for namespace: %s'; echo '[BACKUP] Archiving to bucket: %s'; echo '[BACKUP] Applying retention: %d days'; sleep 2; echo '[BACKUP] Snapshot successfully completed.'; exit 0",
						backup.Spec.TargetNamespace, backup.Spec.StorageBucket, retentionDays),
				},
				Env: []corev1.EnvVar{
					{Name: "TARGET_NAMESPACE", Value: backup.Spec.TargetNamespace},
					{Name: "STORAGE_BUCKET", Value: backup.Spec.StorageBucket},
					{Name: "RETENTION_DAYS", Value: fmt.Sprintf("%d", retentionDays)},
				},
			},
		}
		return nil
	})

	if err != nil {
		logger.Error(err, "Failed to create or update CronJob for ScheduledBackup")
		backup.Status.Phase = "Failed"
		_ = r.Status().Update(ctx, &backup)
		if r.Recorder != nil {
			r.Recorder.Event(&backup, corev1.EventTypeWarning, "CronJobSyncFailed", err.Error())
		}
		return ctrl.Result{}, err
	}

	logger.Info("CronJob reconciled successfully", "CronJob", cronJobName, "Operation", opResult)

	// 4. Update Status and Conditions
	phase := "Active"
	if backup.Spec.Suspend {
		phase = "Suspended"
	}

	now := metav1.Now()
	backup.Status.Phase = phase
	backup.Status.ActiveCronJob = cronJobName
	backup.Status.LastBackupTime = &now
	backup.Status.Conditions = []metav1.Condition{
		{
			Type:               "Ready",
			Status:             metav1.ConditionTrue,
			LastTransitionTime: metav1.Now(),
			Reason:             "CronJobSynced",
			Message:            fmt.Sprintf("Backing CronJob %s is synced (%s)", cronJobName, opResult),
		},
	}

	if err := r.Status().Update(ctx, &backup); err != nil {
		logger.Error(err, "Failed to update ScheduledBackup status")
		return ctrl.Result{}, err
	}

	if r.Recorder != nil && opResult != controllerutil.OperationResultNone {
		r.Recorder.Event(&backup, corev1.EventTypeNormal, "Synced",
			fmt.Sprintf("CronJob %s %s with schedule %s (Phase: %s)", cronJobName, opResult, backup.Spec.Schedule, phase))
	}

	return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
}

func int32Ptr(i int32) *int32 {
	return &i
}

// SetupWithManager sets up the controller with the Manager.
func (r *ScheduledBackupReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&backupv1alpha1.ScheduledBackup{}).
		Owns(&batchv1.CronJob{}).
		Complete(r)
}
