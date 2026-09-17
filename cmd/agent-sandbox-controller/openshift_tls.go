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
	"crypto/tls"

	configv1 "github.com/openshift/api/config/v1"
	openshifttls "github.com/openshift/controller-runtime-common/pkg/tls"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// fetchOpenShiftTLSProfile reads the cluster-wide TLS security profile from
// the OpenShift APIServer CR (apiserver.config.openshift.io/cluster). On
// non-OpenShift clusters the CRD does not exist and this returns an error,
// which callers treat as a no-op fallback to Go defaults.
func fetchOpenShiftTLSProfile(ctx context.Context, cfg *rest.Config) (func(*tls.Config), configv1.TLSProfileSpec, error) {
	s := runtime.NewScheme()
	if err := configv1.Install(s); err != nil {
		return nil, configv1.TLSProfileSpec{}, err
	}

	tempClient, err := client.New(cfg, client.Options{Scheme: s})
	if err != nil {
		return nil, configv1.TLSProfileSpec{}, err
	}

	profileSpec, err := openshifttls.FetchAPIServerTLSProfile(ctx, tempClient)
	if err != nil {
		return nil, configv1.TLSProfileSpec{}, err
	}

	tlsOpt, unsupported := openshifttls.NewTLSConfigFromProfile(profileSpec)
	if len(unsupported) > 0 {
		setupLog.Info("unsupported cipher suites in cluster TLS profile (skipped)", "ciphers", unsupported)
	}

	return tlsOpt, profileSpec, nil
}

// setupSecurityProfileWatcher registers a controller that watches the
// APIServer CR for TLS profile changes. When the profile changes, it
// cancels the manager context to trigger a graceful restart — the pod
// restarts with the updated profile.
func setupSecurityProfileWatcher(mgr ctrl.Manager, initialProfile configv1.TLSProfileSpec, cancel context.CancelFunc) error {
	watcher := &openshifttls.SecurityProfileWatcher{
		Client:                mgr.GetClient(),
		InitialTLSProfileSpec: initialProfile,
		OnProfileChange: func(_ context.Context, _, _ configv1.TLSProfileSpec) {
			setupLog.Info("cluster TLS profile changed, triggering graceful restart")
			cancel()
		},
	}
	return watcher.SetupWithManager(mgr)
}
