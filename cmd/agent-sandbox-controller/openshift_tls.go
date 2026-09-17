// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"context"

	configv1 "github.com/openshift/api/config/v1"
	openshifttls "github.com/openshift/controller-runtime-common/pkg/tls"
	"sigs.k8s.io/agent-sandbox/internal/tlsutil"
	ctrl "sigs.k8s.io/controller-runtime"
)

// setupSecurityProfileWatcher registers a controller that watches the
// APIServer CR for TLS profile and adherence policy changes. When either
// changes, it cancels the manager context to trigger a graceful restart —
// the pod restarts with the updated configuration.
func setupSecurityProfileWatcher(mgr ctrl.Manager, state *tlsutil.OpenShiftTLSState, cancel context.CancelFunc) error {
	watcher := &openshifttls.SecurityProfileWatcher{
		Client:                    mgr.GetClient(),
		InitialTLSProfileSpec:     state.ProfileSpec,
		InitialTLSAdherencePolicy: state.AdherencePolicy,
		OnProfileChange: func(_ context.Context, _, _ configv1.TLSProfileSpec) {
			setupLog.Info("cluster TLS profile changed, triggering graceful restart")
			cancel()
		},
		OnAdherencePolicyChange: func(_ context.Context, old, new configv1.TLSAdherencePolicy) {
			setupLog.Info("cluster TLS adherence policy changed, triggering graceful restart",
				"old", old, "new", new)
			cancel()
		},
	}
	return watcher.SetupWithManager(mgr)
}
