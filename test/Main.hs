{-# LANGUAGE OverloadedStrings #-}
module Main where

import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Test.Hspec

import Nix.Thunk.Internal

main :: IO ()
main = hspec $ do
  describe "parseGitUri" $ do
    describe "radicle URIs" $ do
      it "parses simple radicle URI" $ do
        parseGitUri "rad://z42hL2jL4XNk6K8oHQaSWfMgCL6ji" `shouldSatisfy` isJust

      it "parses radicle URI with node ID" $ do
        parseGitUri "rad://z42hL2jL4XNk6K8oHQaSWfMgCL6ji/z6MksFqXN3Yhqk8pTJdUGLwATkRfQvwZXPqR2qMEhbS9wzpT"
          `shouldSatisfy` isJust

      it "preserves case in radicle RID" $ do
        let uri = "rad://z42hL2jL4XNk6K8oHQaSWfMgCL6ji"
        case parseGitUri uri of
          Nothing -> expectationFailure "Failed to parse radicle URI"
          Just gitUri -> gitUriToText gitUri `shouldBe` uri

      it "preserves case in radicle RID with node ID" $ do
        let uri = "rad://z42hL2jL4XNk6K8oHQaSWfMgCL6ji/z6MksFqXN3Yhqk8pTJdUGLwATkRfQvwZXPqR2qMEhbS9wzpT"
        case parseGitUri uri of
          Nothing -> expectationFailure "Failed to parse radicle URI"
          Just gitUri -> gitUriToText gitUri `shouldBe` uri

    describe "other URI schemes" $ do
      it "parses https URIs" $ do
        parseGitUri "https://github.com/owner/repo.git" `shouldSatisfy` isJust

      it "parses ssh URIs" $ do
        parseGitUri "ssh://git@github.com/owner/repo.git" `shouldSatisfy` isJust

      it "parses file URIs" $ do
        parseGitUri "file:///path/to/repo" `shouldSatisfy` isJust

      it "parses absolute paths as file URIs" $ do
        parseGitUri "/path/to/repo" `shouldSatisfy` isJust

      it "parses ssh shorthand" $ do
        parseGitUri "git@github.com:owner/repo.git" `shouldSatisfy` isJust

  describe "isRadicleUri" $ do
    it "returns True for radicle URIs" $ do
      case parseGitUri "rad://z42hL2jL4XNk6K8oHQaSWfMgCL6ji" of
        Nothing -> expectationFailure "Failed to parse radicle URI"
        Just gitUri -> isRadicleUri gitUri `shouldBe` True

    it "returns False for https URIs" $ do
      case parseGitUri "https://github.com/owner/repo.git" of
        Nothing -> expectationFailure "Failed to parse https URI"
        Just gitUri -> isRadicleUri gitUri `shouldBe` False

    it "returns False for ssh URIs" $ do
      case parseGitUri "ssh://git@github.com/owner/repo.git" of
        Nothing -> expectationFailure "Failed to parse ssh URI"
        Just gitUri -> isRadicleUri gitUri `shouldBe` False

    it "returns False for file URIs" $ do
      case parseGitUri "/path/to/repo" of
        Nothing -> expectationFailure "Failed to parse file URI"
        Just gitUri -> isRadicleUri gitUri `shouldBe` False

  describe "gitUriToText roundtrip" $ do
    let testRoundtrip :: Text -> Expectation
        testRoundtrip uri = case parseGitUri uri of
          Nothing -> expectationFailure $ "Failed to parse URI: " ++ show uri
          Just gitUri -> gitUriToText gitUri `shouldBe` uri

    it "roundtrips radicle URI" $ do
      testRoundtrip "rad://z42hL2jL4XNk6K8oHQaSWfMgCL6ji"

    it "roundtrips radicle URI with node ID" $ do
      testRoundtrip "rad://z42hL2jL4XNk6K8oHQaSWfMgCL6ji/z6MksFqXN3Yhqk8pTJdUGLwATkRfQvwZXPqR2qMEhbS9wzpT"

    it "roundtrips file path" $ do
      testRoundtrip "/path/to/repo"
