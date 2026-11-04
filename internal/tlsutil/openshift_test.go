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

package tlsutil

import (
	"context"
	"crypto/tls"
	"testing"

	"github.com/go-logr/logr"
	configv1 "github.com/openshift/api/config/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestFetchOpenShiftTLSProfile(t *testing.T) {
	s := runtime.NewScheme()
	if err := configv1.Install(s); err != nil {
		t.Fatalf("install config scheme: %v", err)
	}

	apiServer := &configv1.APIServer{
		ObjectMeta: metav1.ObjectMeta{Name: "cluster"},
		Spec: configv1.APIServerSpec{
			TLSSecurityProfile: &configv1.TLSSecurityProfile{Type: configv1.TLSProfileModernType},
			TLSAdherence:       configv1.TLSAdherencePolicyStrictAllComponents,
		},
	}
	cl := fake.NewClientBuilder().WithScheme(s).WithObjects(apiServer).Build()

	state, err := fetchOpenShiftTLSProfile(context.Background(), cl, logr.Discard())
	if err != nil {
		t.Fatalf("fetchOpenShiftTLSProfile: %v", err)
	}

	if state.AdherencePolicy != configv1.TLSAdherencePolicyStrictAllComponents {
		t.Errorf("AdherencePolicy: got %q, want %q", state.AdherencePolicy, configv1.TLSAdherencePolicyStrictAllComponents)
	}
	if state.ProfileSpec.MinTLSVersion != configv1.VersionTLS13 {
		t.Errorf("MinTLSVersion: got %q, want %q", state.ProfileSpec.MinTLSVersion, configv1.VersionTLS13)
	}
	if state.TLSOpt == nil {
		t.Fatal("TLSOpt is nil")
	}
	tc := &tls.Config{}
	state.TLSOpt(tc)
	if tc.MinVersion != tls.VersionTLS13 {
		t.Errorf("applied MinVersion: got %d, want %d", tc.MinVersion, tls.VersionTLS13)
	}
}

func TestFetchOpenShiftTLSProfileMissingAPIServer(t *testing.T) {
	s := runtime.NewScheme()
	if err := configv1.Install(s); err != nil {
		t.Fatalf("install config scheme: %v", err)
	}
	cl := fake.NewClientBuilder().WithScheme(s).Build()

	if _, err := fetchOpenShiftTLSProfile(context.Background(), cl, logr.Discard()); err == nil {
		t.Fatal("expected an error when the APIServer CR is absent")
	}
}
