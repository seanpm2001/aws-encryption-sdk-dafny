// Copyright Amazon.com Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
// Do not modify this file. This file is machine generated, and any changes to it will be overwritten.

using System;
using AWS.EncryptionSDK.Core;

namespace AWS.EncryptionSDK.Core
{
    public class EncryptedDataKey
    {
        private string _keyProviderId;
        private System.IO.MemoryStream _keyProviderInfo;
        private System.IO.MemoryStream _ciphertext;

        public string KeyProviderId
        {
            get { return this._keyProviderId; }
            set { this._keyProviderId = value; }
        }

        internal bool IsSetKeyProviderId()
        {
            return this._keyProviderId != null;
        }

        public System.IO.MemoryStream KeyProviderInfo
        {
            get { return this._keyProviderInfo; }
            set { this._keyProviderInfo = value; }
        }

        internal bool IsSetKeyProviderInfo()
        {
            return this._keyProviderInfo != null;
        }

        public System.IO.MemoryStream Ciphertext
        {
            get { return this._ciphertext; }
            set { this._ciphertext = value; }
        }

        internal bool IsSetCiphertext()
        {
            return this._ciphertext != null;
        }

        public void Validate()
        {
            if (!IsSetKeyProviderId())
                throw new System.ArgumentException("Missing value for required property 'KeyProviderId'");
            if (!IsSetKeyProviderInfo())
                throw new System.ArgumentException("Missing value for required property 'KeyProviderInfo'");
            if (!IsSetCiphertext())
                throw new System.ArgumentException("Missing value for required property 'Ciphertext'");
        }
    }
}
