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
	"fmt"

	"github.com/go-logr/logr"
	configv1 "github.com/openshift/api/config/v1"
	openshifttls "github.com/openshift/controller-runtime-common/pkg/tls"
	"k8s.io/apimachinery/pkg/api/equality"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// tryApplyOpenShiftTLS attempts to read the cluster-wide TLS security profile
// from the OpenShift APIServer CR and apply it to tlsConfig. If successful it
// also starts a background goroutine that watches for profile changes and
// cancels the returned context to trigger a graceful restart. On non-OpenShift
// clusters the CRD does not exist and the original ctx is returned unchanged.
func tryApplyOpenShiftTLS(ctx context.Context, kubeconfig string, tlsConfig *tls.Config, log logr.Logger) context.Context {
	restCfg, err := loadRESTConfig(kubeconfig)
	if err != nil {
		return ctx
	}
	tlsOpt, profile, err := fetchOpenShiftTLSProfile(ctx, restCfg)
	if err != nil {
		log.V(4).Info("OpenShift TLS profile not available, using defaults", "error", err)
		return ctx
	}
	tlsOpt(tlsConfig)
	log.Info("applied OpenShift cluster TLS profile")

	ctx, cancel := context.WithCancel(ctx)
	if err := watchAndExitOnTLSChange(ctx, restCfg, profile, cancel); err != nil {
		log.Error(err, "failed to start TLS profile watcher")
	}
	return ctx
}

// fetchOpenShiftTLSProfile reads the cluster-wide TLS security profile from
// the OpenShift APIServer CR (apiserver.config.openshift.io/cluster). On
// non-OpenShift clusters the CRD does not exist and this returns an error,
// which callers treat as a no-op fallback to Go defaults.
func fetchOpenShiftTLSProfile(ctx context.Context, cfg *rest.Config) (func(*tls.Config), *configv1.TLSSecurityProfile, error) {
	s := runtime.NewScheme()
	if err := configv1.Install(s); err != nil {
		return nil, nil, err
	}

	cl, err := client.New(cfg, client.Options{Scheme: s})
	if err != nil {
		return nil, nil, err
	}

	profileSpec, err := openshifttls.FetchAPIServerTLSProfile(ctx, cl)
	if err != nil {
		return nil, nil, err
	}

	tlsOpt, unsupported := openshifttls.NewTLSConfigFromProfile(profileSpec)
	if len(unsupported) > 0 {
		ctrl.Log.WithName("openshift-tls").Info("unsupported cipher suites in cluster TLS profile (skipped)", "ciphers", unsupported)
	}

	apiServer := &configv1.APIServer{}
	if err := cl.Get(ctx, client.ObjectKey{Name: "cluster"}, apiServer); err != nil {
		return nil, nil, fmt.Errorf("get APIServer: %w", err)
	}

	return tlsOpt, apiServer.Spec.TLSSecurityProfile, nil
}

// watchAndExitOnTLSChange watches the APIServer CR for changes to the TLS
// security profile. When a change is detected, it calls cancel() to trigger
// a graceful shutdown so the pod restarts with the new profile.
func watchAndExitOnTLSChange(ctx context.Context, cfg *rest.Config, current *configv1.TLSSecurityProfile, cancel context.CancelFunc) error {
	s := runtime.NewScheme()
	if err := configv1.Install(s); err != nil {
		return fmt.Errorf("install config scheme: %w", err)
	}

	wc, err := client.NewWithWatch(cfg, client.Options{Scheme: s})
	if err != nil {
		return fmt.Errorf("build watch client: %w", err)
	}

	w, err := wc.Watch(ctx, &configv1.APIServerList{})
	if err != nil {
		return fmt.Errorf("watch APIServers: %w", err)
	}

	go func() {
		defer w.Stop()
		log := ctrl.Log.WithName("openshift-tls")
		for {
			select {
			case <-ctx.Done():
				return
			case event, ok := <-w.ResultChan():
				if !ok {
					return
				}
				if event.Type != watch.Modified {
					continue
				}
				updated, ok := event.Object.(*configv1.APIServer)
				if !ok {
					continue
				}
				if !equality.Semantic.DeepEqual(current, updated.Spec.TLSSecurityProfile) {
					log.Info("cluster TLS profile changed, triggering graceful restart")
					cancel()
					return
				}
			}
		}
	}()

	return nil
}
