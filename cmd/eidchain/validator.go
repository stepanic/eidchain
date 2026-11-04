package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"eidchain/internal/chain"
	"eidchain/internal/remote"
)

func cmdKeygen(args []string) error {
	fs := newFlagSet("keygen")
	data := fs.String("data", defaultData(), "data directory")
	out := fs.String("out", "", "private key file to write (default <data>/keys/validator.key, where the node loads it from)")
	if _, err := parse(fs, args); err != nil {
		return err
	}
	if *out == "" {
		*out = filepath.Join(*data, "keys", "validator.key")
	}
	key, err := chain.GenerateKey()
	if err != nil {
		return err
	}
	if err := chain.SavePrivateKey(*out, key); err != nil {
		return err
	}
	id, _ := chain.KeyID(&key.PublicKey)
	pub, _ := chain.EncodePublicKey(&key.PublicKey)
	fmt.Printf("Wrote %s (readable only by you; it never leaves this machine)\nkey ID:     %s\npublic key: %s\n", *out, id, pub)
	return nil
}

const validatorUsage = `usage:
  eidchain validator request [--key FILE] [--retire KEY-ID] [--server URL] [--out registration.json]
  eidchain validator retire  KEY-ID [--server URL] [--out registration.json]

"request" writes the record that makes a node's key a validator (feature
eid-validators). Sign it with your eID card on the node's web page
(validator.html) and it goes into the next block. The key signs the record too,
to show it is yours; the private key itself stays here. With --retire the same
record also drops one of your other keys, e.g. one of a node you shut down.
"retire" writes a record that only drops one of your keys.

You may run several validating nodes, each with its own key (never copy a key
to a second node). All your keys count as one person: they take turns with
other people, and approve rotations once. A key counts toward the authorities
once it has signed a block. Registering a key again, with a new card, renews it.`

func cmdValidator(args []string) error {
	if len(args) == 0 || (args[0] != "request" && args[0] != "retire") {
		return errors.New(validatorUsage)
	}
	op := args[0]
	fs := newFlagSet("validator " + op)
	data := fs.String("data", defaultData(), "data directory (to find a configured peer)")
	server := fs.String("server", "", "node URL, to learn the chain's genesis hash")
	keyPath := fs.String("key", "", "the node's key (default <data>/keys/validator.key)")
	retire := fs.String("retire", "", "ID (or unique prefix) of one of your keys to drop")
	out := fs.String("out", "registration.json", "file to write the record to")
	pos, err := parse(fs, args[1:])
	if err != nil {
		return err
	}
	var signer *chain.Signer
	if op == "retire" {
		if len(pos) != 1 {
			return errors.New(validatorUsage)
		}
		*retire = pos[0]
	} else {
		if *keyPath == "" {
			*keyPath = filepath.Join(*data, "keys", "validator.key")
		}
		key, err := chain.LoadPrivateKey(*keyPath)
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("%s does not exist: create it with `eidchain keygen`", *keyPath)
		} else if err != nil {
			return err
		}
		id, _ := chain.KeyID(&key.PublicKey)
		signer = &chain.Signer{ID: id, Key: key}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	url := serverArg(*server, *data)
	info, err := remote.New(url).Info(ctx)
	if err != nil {
		return err
	}
	if _, ok := info.Features[chain.FeatureEIDValidators]; !ok {
		fmt.Fprintf(os.Stderr, "warning: %s does not schedule %s; it will refuse the record\n", url, chain.FeatureEIDValidators)
	}
	if *retire != "" {
		if *retire, err = matchKey(*retire, append(info.Authorities, info.Candidates...)); err != nil {
			return err
		}
	}
	text, err := chain.NewRegistration(info.GenesisHash, signer, *retire, time.Now())
	if err != nil {
		return err
	}
	if err := os.WriteFile(*out, []byte(text+"\n"), 0o644); err != nil {
		return err
	}
	what := "retiring key " + *retire
	if signer != nil {
		what = "for key " + signer.ID
		if *retire != "" {
			what += ", retiring key " + *retire
		}
	}
	fmt.Printf("Wrote %s %s on chain %s:\n\n%s\n\nOpen %s/validator.html, paste it and sign with your eID card.\n",
		*out, what, info.GenesisHash.Short(), text, strings.TrimSuffix(url, "/"))
	return nil
}

// matchKey resolves a key ID prefix among ids.
func matchKey(prefix string, ids []string) (string, error) {
	found := ""
	for _, id := range ids {
		if strings.HasPrefix(id, prefix) {
			if found != "" {
				return "", fmt.Errorf("key %q is ambiguous", prefix)
			}
			found = id
		}
	}
	if found == "" {
		return "", fmt.Errorf("no validator key matches %q", prefix)
	}
	return found, nil
}
