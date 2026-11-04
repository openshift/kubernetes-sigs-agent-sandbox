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
	inttls "sigs.k8s.io/agent-sandbox/internal/tlsutil"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// tryApplyOpenShiftTLS attempts to read the cluster-wide TLS security profile
// and adherence policy from the OpenShift APIServer CR and apply it to every
// non-nil TLS config (proxy and metrics). If successful it also starts a
// background goroutine that watches for profile or adherence policy changes
// and cancels the returned context to trigger a graceful restart. On
// non-OpenShift clusters the CRD does not exist and the original ctx is
// returned unchanged.
//
// When cliTLSFlagsSet is true the caller has explicit TLS flags on the command
// line. The cluster profile is still applied when the adherence policy is
// StrictAllComponents (overriding CLI flags); otherwise it is skipped.
func tryApplyOpenShiftTLS(ctx context.Context, kubeconfig string, tlsConfigs []*tls.Config, cliTLSFlagsSet bool, log logr.Logger) context.Context {
	restCfg, err := loadRESTConfig(kubeconfig)
	if err != nil {
		return ctx
	}
	state, err := inttls.FetchOpenShiftTLSProfile(ctx, restCfg, log)
	if err != nil {
		log.V(4).Info("OpenShift TLS profile not available, using defaults", "error", err)
		return ctx
	}

	strict := state.AdherencePolicy == configv1.TLSAdherencePolicyStrictAllComponents
	if strict || !cliTLSFlagsSet {
		for _, tc := range tlsConfigs {
			if tc != nil {
				state.TLSOpt(tc)
			}
		}
		log.Info("applied OpenShift cluster TLS profile", "tlsAdherence", state.AdherencePolicy)
	}

	ctx, cancel := context.WithCancel(ctx)
	if err := watchAndExitOnTLSChange(ctx, restCfg, state.ProfileSpec, state.AdherencePolicy, cancel); err != nil {
		log.Error(err, "failed to start TLS profile watcher")
	}
	return ctx
}

// watchAndExitOnTLSChange watches the APIServer CR for changes to the TLS
// security profile or adherence policy. When a change is detected, it calls
// cancel() to trigger a graceful shutdown so the pod restarts with the new
// configuration.
func watchAndExitOnTLSChange(ctx context.Context, cfg *rest.Config, currentProfile configv1.TLSProfileSpec, currentAdherence configv1.TLSAdherencePolicy, cancel context.CancelFunc) error {
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
				updatedProfile, err := openshifttls.GetTLSProfileSpec(updated.Spec.TLSSecurityProfile)
				if err != nil {
					log.Error(err, "failed to resolve cluster TLS profile, skipping event")
					continue
				}
				if !equality.Semantic.DeepEqual(currentProfile, updatedProfile) {
					log.Info("cluster TLS profile changed, triggering graceful restart")
					cancel()
					return
				}
				if currentAdherence != updated.Spec.TLSAdherence {
					log.Info("cluster TLS adherence policy changed, triggering graceful restart",
						"old", currentAdherence, "new", updated.Spec.TLSAdherence)
					cancel()
					return
				}
			}
		}
	}()

	return nil
}
