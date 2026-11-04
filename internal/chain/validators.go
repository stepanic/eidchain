package chain

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
)

// Validators registered with an eID card (feature eid-validators).
//
// The card does not sign blocks: that needs a PIN for every signature and a
// person at the reader. It signs once per node, a record that names a key the
// node holds, and that key signs the blocks. The person is identified by the
// certificate's serialNumber, which on a national eID card is the personal ID
// number and stays the same when the card is replaced.
//
// A person may run several nodes, in several places, so that their validator
// survives losing one. Each has its own key (one key on two nodes would sign
// two blocks at once), but all of a person's keys are one voter (State.Voter):
// the signer window and the quorum count people, not keys, so more keys buy
// availability and no extra say.
//
// A registered key is a candidate: it may sign blocks but does not count toward
// N, the number the signer window and the quorum are taken from. It is counted
// from the first block it signs. Without that, registering keys that no node runs
// would raise N until the running keys could not fill the signer window, and the
// chain would stop. For the same reason a counted key that has signed nothing for
// IdleBlocks becomes a candidate again; signing a block counts it once more.
//
// A key stops being a validator when its card's certificate expires. A revoked
// certificate is not noticed: that would need OCSP evidence in the chain.

const validatorDomain = "eidchain/validator/v1\n"

// Holder is the person who registered a validator key.
type Holder struct {
	Identity string // the certificate subject's serialNumber ("PNOHR-" + OIB); never shown
	Name     string // the certificate's common name, for display
	NotAfter int64  // the certificate's expiry, unix seconds: the key is dropped then
}

// MaxKeysPerPerson caps the keys one person may register, so that one card
// cannot grow the state without bound.
const MaxKeysPerPerson = 16

// Registration is a payload by which a person adds a validator key, retires one
// of theirs, or both. Its eID signature says who; Proof, made with the key
// itself, shows the registrant holds that key, so nobody can enrol a key of
// someone else's. Registering a key the person already holds renews it with the
// certificate that signed this record, which matters once a card is replaced.
type Registration struct {
	Type    string `json:"type"` // "validator"
	Chain   Hash   `json:"chain"`
	Key     string `json:"key,omitempty"`    // base64 DER SPKI (ECDSA P-256)
	Proof   string `json:"proof,omitempty"`  // base64 ASN.1 ECDSA by Key over RegistrationHash
	Retire  string `json:"retire,omitempty"` // key ID of the person's own key to drop
	Created string `json:"created,omitempty"`
}

// RegistrationHash is what the registered key signs: this chain and that key.
func RegistrationHash(chain Hash, key string) Hash {
	v := struct {
		Chain Hash   `json:"chain"`
		Key   string `json:"key"`
	}{chain, key}
	return sha256.Sum256(append([]byte(validatorDomain), canonical(v)...))
}

// NewRegistration returns the payload text that registers s on chain, and
// retires the key with ID retire if that is not empty, for a person to sign
// with their eID card. s may be nil to only retire.
func NewRegistration(chain Hash, s *Signer, retire string, created time.Time) (string, error) {
	r := Registration{Type: "validator", Chain: chain, Retire: retire, Created: created.UTC().Format(time.RFC3339)}
	if s != nil {
		key, err := EncodePublicKey(&s.Key.PublicKey)
		if err != nil {
			return "", err
		}
		h := RegistrationHash(chain, key)
		sig, err := ecdsa.SignASN1(rand.Reader, s.Key, h[:])
		if err != nil {
			return "", err
		}
		r.Key, r.Proof = key, base64.StdEncoding.EncodeToString(sig)
	}
	return string(canonical(r)), nil
}

// ParseRegistration returns the registration in a payload; ok is false if the
// payload is some other record.
func ParseRegistration(payload string) (r Registration, ok bool, err error) {
	var head struct {
		Type string `json:"type"`
	}
	if json.Unmarshal([]byte(payload), &head) != nil || head.Type != "validator" {
		return r, false, nil
	}
	if err := json.Unmarshal([]byte(payload), &r); err != nil {
		return r, true, fmt.Errorf("validator registration: %w", err)
	}
	return r, true, nil
}

// holderOf identifies the person a certificate was issued to. Only a natural
// person's ID number ("PNO", ETSI EN 319 412-1) qualifies: it is what limits a
// person to one key.
func holderOf(c *x509.Certificate) (Holder, error) {
	sn := c.Subject.SerialNumber
	if !strings.HasPrefix(sn, "PNO") {
		return Holder{}, errors.New("the certificate does not carry a personal ID number, so it cannot register a validator")
	}
	return Holder{Identity: sn, Name: SubjectName(c), NotAfter: c.NotAfter.Unix()}, nil
}

// keysOf counts the keys held by a person.
func (s *State) keysOf(identity string) int {
	n := 0
	for _, h := range s.Holders {
		if h.Identity == identity {
			n++
		}
	}
	return n
}

// ApplyRegistration returns the state after e, a payload of a block at height
// signed by cert, if e is a validator registration and the feature is active.
// Any other payload leaves working as it is.
func (p *Params) ApplyRegistration(working *State, e PayloadEntry, cert *x509.Certificate, height uint64, at time.Time) (*State, error) {
	if !p.Features.Active(FeatureEIDValidators, height) {
		return working, nil
	}
	r, ok, err := ParseRegistration(e.Payload)
	if !ok || err != nil {
		return working, err
	}
	if r.Chain != p.GenesisHash {
		return nil, errors.New("validator registration is for a different chain")
	}
	if r.Key == "" && r.Retire == "" {
		return nil, errors.New("validator registration: neither a key to add nor one to retire")
	}
	holder, err := holderOf(cert)
	if err != nil {
		return nil, err
	}
	if at.Unix() >= holder.NotAfter {
		return nil, errors.New("validator registration: the certificate has expired")
	}
	c := working.clone()
	if r.Retire != "" {
		if h, ok := c.Holders[r.Retire]; !ok || h.Identity != holder.Identity {
			return nil, errors.New("validator registration: the key to retire is not one of yours")
		}
		c.drop(r.Retire)
	}
	if r.Key == "" {
		return c, nil
	}
	pub, err := DecodePublicKey(r.Key)
	if err != nil {
		return nil, fmt.Errorf("validator registration: key: %w", err)
	}
	sig, err := decodeB64(r.Proof)
	h := RegistrationHash(r.Chain, r.Key)
	if err != nil || !ecdsa.VerifyASN1(pub, h[:], sig) {
		return nil, errors.New("validator registration: the proof is not the key's signature")
	}
	id, _ := KeyID(pub)
	switch held, ok := c.Holders[id]; {
	case ok && held.Identity == holder.Identity: // renewal
	case c.Has(id) || id == r.Retire:
		return nil, errors.New("validator registration: the key is already a validator")
	case c.keysOf(holder.Identity) >= MaxKeysPerPerson:
		return nil, fmt.Errorf("validator registration: a person may hold at most %d keys; retire one first", MaxKeysPerPerson)
	default:
		c.Candidates = append(c.Candidates, id)
		c.Keys[id] = pub
		c.LastSigned[id] = height
	}
	c.Holders[id] = holder
	return c, nil
}

// IdleBlocks is how many blocks a counted key may go without signing before it
// stops being counted. Blocks are only made when there is something to put in
// them and the first node to cut one wins, so a running key can miss many turns;
// this leaves it several.
func IdleBlocks(st *State) uint64 { return uint64(max(16, 4*len(st.IDs))) }

// settle applies what follows from a block at height, signed by signer at time
// t, once its payloads and rotations are in st: the signer is counted, expired
// keys go, and keys idle for too long stop being counted.
func (p *Params) settle(st *State, signer string, height uint64, t int64) *State {
	c := st.clone()
	if c.Has(signer) { // a rotation or registration in the block may have replaced it
		c.LastSigned[signer] = height
		if !c.Active(signer) {
			c.Candidates = slices.DeleteFunc(c.Candidates, func(x string) bool { return x == signer })
			c.IDs = append(c.IDs, signer)
		}
	}
	for id := range c.Holders {
		if c.Expired(id, t) {
			c.drop(id)
		}
	}
	idle := IdleBlocks(c)
	for _, id := range slices.Clone(c.IDs) {
		last, ok := c.LastSigned[id]
		switch {
		case !ok: // counted before the feature or added by a rotation: the clock starts now
			c.LastSigned[id] = height
		case id != signer && height-last >= idle:
			c.IDs = slices.DeleteFunc(c.IDs, func(x string) bool { return x == id })
			c.Candidates = append(c.Candidates, id)
		}
	}
	return c
}
