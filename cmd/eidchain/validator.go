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
  eidchain validator request [--key FILE] [--server URL] [--out registration.json]

Writes the record that makes a node's key a validator (feature eid-validators).
Sign it with your eID card on the node's web page (validator.html) and it goes
into the next block. The key signs the record too, to show it is yours; the
private key itself stays here.

One person holds one validator key: registering another replaces the first.
The key counts toward the authorities once it has signed a block.`

func cmdValidator(args []string) error {
	if len(args) == 0 || args[0] != "request" {
		return errors.New(validatorUsage)
	}
	fs := newFlagSet("validator request")
	data := fs.String("data", defaultData(), "data directory (to find a configured peer)")
	server := fs.String("server", "", "node URL, to learn the chain's genesis hash")
	keyPath := fs.String("key", "", "the node's key (default <data>/keys/validator.key)")
	out := fs.String("out", "registration.json", "file to write the record to")
	if _, err := parse(fs, args[1:]); err != nil {
		return err
	}
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
	text, err := chain.NewRegistration(info.GenesisHash, chain.Signer{ID: id, Key: key}, time.Now())
	if err != nil {
		return err
	}
	if err := os.WriteFile(*out, []byte(text+"\n"), 0o644); err != nil {
		return err
	}
	fmt.Printf("Wrote %s for key %s on chain %s:\n\n%s\n\nOpen %s/validator.html, paste it and sign with your eID card.\n",
		*out, id, info.GenesisHash.Short(), text, strings.TrimSuffix(url, "/"))
	return nil
}
