// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (proxy/Clones.sol)

pragma solidity ^0.8.0;

/**
 * @dev https://eips.ethereum.org/EIPS/eip-1167[EIP 1167] is a standard for
 * deploying minimal proxy contracts, also known as "clones".
 *
 * > To simply and cheaply clone contract functionality in an immutable way, this standard specifies
 * > a minimal bytecode implementation that delegates all calls to a known, fixed address.
 *
 * The library includes functions to deploy a proxy using either `create` (traditional deployment) or `create2`
 * (salted deterministic deployment). It also includes functions to predict the addresses of clones deployed using the
 * deterministic method.
 *
 * _Available since v3.4._
 */
library Clones {
    /**
     * @dev Deploys and returns the address of a clone that mimics the behaviour of `implementation`.
     *
     * This function uses the create opcode, which should never revert.
     */
    function clone(address implementation) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        require(instance != address(0), "ERC1167: create failed");
    }

    /**
     * @dev Deploys and returns the address of a clone that mimics the behaviour of `implementation`.
     *
     * This function uses the create2 opcode and a `salt` to deterministically deploy
     * the clone. Using the same `implementation` and `salt` multiple time will revert, since
     * the clones cannot be deployed twice at the same address.
     */
    function cloneDeterministic(address implementation, bytes32 salt) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "ERC1167: create2 failed");
    }

    /**
     * @dev Computes the address of a clone deployed using {Clones-cloneDeterministic}.
     */
    function predictDeterministicAddress(
        address implementation,
        bytes32 salt,
        address deployer
    ) internal pure returns (address predicted) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf3ff00000000000000000000000000000000)
            mstore(add(ptr, 0x38), shl(0x60, deployer))
            mstore(add(ptr, 0x4c), salt)
            mstore(add(ptr, 0x6c), keccak256(ptr, 0x37))
            predicted := keccak256(add(ptr, 0x37), 0x55)
        }
    }

    /**
     * @dev Computes the address of a clone deployed using {Clones-cloneDeterministic}.
     */
    function predictDeterministicAddress(address implementation, bytes32 salt)
        internal
        view
        returns (address predicted)
    {
        return predictDeterministicAddress(implementation, salt, address(this));
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.5.0) (utils/Base64.sol)

pragma solidity ^0.8.0;

/**
 * @dev Provides a set of functions to operate with Base64 strings.
 *
 * _Available since v4.5._
 */
library Base64 {
    /**
     * @dev Base64 Encoding/Decoding Table
     */
    string internal constant _TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    /**
     * @dev Converts a `bytes` to its Bytes64 `string` representation.
     */
    function encode(bytes memory data) internal pure returns (string memory) {
        /**
         * Inspired by Brecht Devos (Brechtpd) implementation - MIT licence
         * https://github.com/Brechtpd/base64/blob/e78d9fd951e7b0977ddca77d92dc85183770daf4/base64.sol
         */
        if (data.length == 0) return "";

        // Loads the table into memory
        string memory table = _TABLE;

        // Encoding takes 3 bytes chunks of binary data from `bytes` data parameter
        // and split into 4 numbers of 6 bits.
        // The final Base64 length should be `bytes` data length multiplied by 4/3 rounded up
        // - `data.length + 2`  -> Round up
        // - `/ 3`              -> Number of 3-bytes chunks
        // - `4 *`              -> 4 characters for each chunk
        string memory result = new string(4 * ((data.length + 2) / 3));

        assembly {
            // Prepare the lookup table (skip the first "length" byte)
            let tablePtr := add(table, 1)

            // Prepare result pointer, jump over length
            let resultPtr := add(result, 32)

            // Run over the input, 3 bytes at a time
            for {
                let dataPtr := data
                let endPtr := add(data, mload(data))
            } lt(dataPtr, endPtr) {

            } {
                // Advance 3 bytes
                dataPtr := add(dataPtr, 3)
                let input := mload(dataPtr)

                // To write each character, shift the 3 bytes (18 bits) chunk
                // 4 times in blocks of 6 bits for each character (18, 12, 6, 0)
                // and apply logical AND with 0x3F which is the number of
                // the previous character in the ASCII table prior to the Base64 Table
                // The result is then added to the table to get the character to write,
                // and finally write it in the result pointer but with a left shift
                // of 256 (1 byte) - 8 (1 ASCII char) = 248 bits

                mstore8(resultPtr, mload(add(tablePtr, and(shr(18, input), 0x3F))))
                resultPtr := add(resultPtr, 1) // Advance

                mstore8(resultPtr, mload(add(tablePtr, and(shr(12, input), 0x3F))))
                resultPtr := add(resultPtr, 1) // Advance

                mstore8(resultPtr, mload(add(tablePtr, and(shr(6, input), 0x3F))))
                resultPtr := add(resultPtr, 1) // Advance

                mstore8(resultPtr, mload(add(tablePtr, and(input, 0x3F))))
                resultPtr := add(resultPtr, 1) // Advance
            }

            // When data `bytes` is not exactly 3 bytes long
            // it is padded with `=` characters at the end
            switch mod(mload(data), 3)
            case 1 {
                mstore8(sub(resultPtr, 1), 0x3d)
                mstore8(sub(resultPtr, 2), 0x3d)
            }
            case 2 {
                mstore8(sub(resultPtr, 1), 0x3d)
            }
        }

        return result;
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (utils/Strings.sol)

pragma solidity ^0.8.0;

/**
 * @dev String operations.
 */
library Strings {
    bytes16 private constant _HEX_SYMBOLS = "0123456789abcdef";

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        // Inspired by OraclizeAPI's implementation - MIT licence
        // https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol

        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation.
     */
    function toHexString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0x00";
        }
        uint256 temp = value;
        uint256 length = 0;
        while (temp != 0) {
            length++;
            temp >>= 8;
        }
        return toHexString(value, length);
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation with fixed length.
     */
    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = _HEX_SYMBOLS[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "Strings: hex length insufficient");
        return string(buffer);
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.5.0) (utils/cryptography/ECDSA.sol)

pragma solidity ^0.8.0;

import "../Strings.sol";

/**
 * @dev Elliptic Curve Digital Signature Algorithm (ECDSA) operations.
 *
 * These functions can be used to verify that a message was signed by the holder
 * of the private keys of a given address.
 */
library ECDSA {
    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS,
        InvalidSignatureV
    }

    function _throwError(RecoverError error) private pure {
        if (error == RecoverError.NoError) {
            return; // no error: do nothing
        } else if (error == RecoverError.InvalidSignature) {
            revert("ECDSA: invalid signature");
        } else if (error == RecoverError.InvalidSignatureLength) {
            revert("ECDSA: invalid signature length");
        } else if (error == RecoverError.InvalidSignatureS) {
            revert("ECDSA: invalid signature 's' value");
        } else if (error == RecoverError.InvalidSignatureV) {
            revert("ECDSA: invalid signature 'v' value");
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature` or error string. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {toEthSignedMessageHash} on it.
     *
     * Documentation for signature generation:
     * - with https://web3js.readthedocs.io/en/v1.3.4/web3-eth-accounts.html#sign[Web3.js]
     * - with https://docs.ethers.io/v5/api/signer/#Signer-signMessage[ethers]
     *
     * _Available since v4.3._
     */
    function tryRecover(bytes32 hash, bytes memory signature) internal pure returns (address, RecoverError) {
        // Check the signature length
        // - case 65: r,s,v signature (standard)
        // - case 64: r,vs signature (cf https://eips.ethereum.org/EIPS/eip-2098) _Available since v4.1._
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            return tryRecover(hash, v, r, s);
        } else if (signature.length == 64) {
            bytes32 r;
            bytes32 vs;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            assembly {
                r := mload(add(signature, 0x20))
                vs := mload(add(signature, 0x40))
            }
            return tryRecover(hash, r, vs);
        } else {
            return (address(0), RecoverError.InvalidSignatureLength);
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature`. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {toEthSignedMessageHash} on it.
     */
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, signature);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `r` and `vs` short-signature fields separately.
     *
     * See https://eips.ethereum.org/EIPS/eip-2098[EIP-2098 short signatures]
     *
     * _Available since v4.3._
     */
    function tryRecover(
        bytes32 hash,
        bytes32 r,
        bytes32 vs
    ) internal pure returns (address, RecoverError) {
        bytes32 s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        uint8 v = uint8((uint256(vs) >> 255) + 27);
        return tryRecover(hash, v, r, s);
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `r and `vs` short-signature fields separately.
     *
     * _Available since v4.2._
     */
    function recover(
        bytes32 hash,
        bytes32 r,
        bytes32 vs
    ) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, r, vs);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `v`,
     * `r` and `s` signature fields separately.
     *
     * _Available since v4.3._
     */
    function tryRecover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address, RecoverError) {
        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return (address(0), RecoverError.InvalidSignatureS);
        }
        if (v != 27 && v != 28) {
            return (address(0), RecoverError.InvalidSignatureV);
        }

        // If the signature is valid (and not malleable), return the signer address
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) {
            return (address(0), RecoverError.InvalidSignature);
        }

        return (signer, RecoverError.NoError);
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function recover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, v, r, s);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Returns an Ethereum Signed Message, created from a `hash`. This
     * produces hash corresponding to the one signed with the
     * https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`]
     * JSON-RPC method as part of EIP-191.
     *
     * See {recover}.
     */
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        // 32 is the length in bytes of hash,
        // enforced by the type signature above
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    /**
     * @dev Returns an Ethereum Signed Message, created from `s`. This
     * produces hash corresponding to the one signed with the
     * https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`]
     * JSON-RPC method as part of EIP-191.
     *
     * See {recover}.
     */
    function toEthSignedMessageHash(bytes memory s) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", Strings.toString(s.length), s));
    }

    /**
     * @dev Returns an Ethereum Signed Typed Data, created from a
     * `domainSeparator` and a `structHash`. This produces hash corresponding
     * to the one signed with the
     * https://eips.ethereum.org/EIPS/eip-712[`eth_signTypedData`]
     * JSON-RPC method as part of EIP-712.
     *
     * See {recover}.
     */
    function toTypedDataHash(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {Ownable} from "../lib/Ownable.sol";

interface IMirrorFeeConfigurationEvents {
    event FeeSwitch(bool on);

    event MinimumFee(uint16 fee);

    event MaximumFee(uint16 fee);
}

interface IMirrorFeeConfiguration {
    function on() external returns (bool);

    function maximumFee() external returns (uint16);

    function minimumFee() external returns (uint16);

    function switchFee() external;

    function updateMinimumFee(uint16 newFee) external;

    function updateMaximumFee(uint16 newFe) external;

    function valid(uint16) external view returns (bool);
}

/**
 * @title MirrorFeeConfiguration
 * Allows to turn fees on and off. Fee values are stored in Basis Points.
 * @author MirrorXYZ
 */
contract MirrorFeeConfiguration is
    Ownable,
    IMirrorFeeConfiguration,
    IMirrorFeeConfigurationEvents
{
    bool public on = false;

    uint16 public override minimumFee = 250;

    uint16 public override maximumFee = 500;

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Toggle fees on/off.
    function switchFee() external onlyOwner {
        on = !on;

        emit FeeSwitch(on);
    }

    /// @notice Update the minimum fee allowed.
    function updateMinimumFee(uint16 newFee) external override onlyOwner {
        require(newFee <= maximumFee, "cannot update");

        minimumFee = newFee;

        emit MinimumFee(newFee);
    }

    /// @notice Update the maximum fee allowed.
    function updateMaximumFee(uint16 newFee) external override onlyOwner {
        require(newFee >= minimumFee, "cannot update");

        maximumFee = newFee;

        emit MaximumFee(newFee);
    }

    /// @notice Check if a fee is valid.
    function valid(uint16 fee) external view returns (bool) {
        return (minimumFee <= fee) && (fee <= maximumFee);
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @dev Interafce for EIP-1271: Standard Signature Validation Method for Contracts.
interface IERC1271 {
    /// @dev Should return whether the signature provided is valid for the provided hash
    /// @param salt      Hash of the data to be signed
    /// @param signature Signature byte array associated with _hash
    /// MUST return the bytes4 magic value 0x1626ba7e when function passes.
    /// MUST NOT modify state (using STATICCALL for solc < 0.5, view modifier for solc > 0.5)
    /// MUST allow external calls
    function isValidSignature(bytes32 salt, bytes memory signature)
        external
        view
        returns (bytes4 magicValue);
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

abstract contract ERC165 is IERC165 {
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override
        returns (bool)
    {
        return interfaceId == type(IERC165).interfaceId;
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/**
 * @title IERC2981
 * @notice Interface for the NFT Royalty Standard
 */
interface IERC2981 {
    // / bytes4(keccak256("royaltyInfo(uint256,uint256)")) == 0x2a55205a

    /**
     * @notice Called with the sale price to determine how much royalty
     *         is owed and to whom.
     * @param _tokenId - the NFT asset queried for royalty information
     * @param _salePrice - the sale price of the NFT asset specified by _tokenId
     * @return receiver - address of who should be sent the royalty payment
     * @return royaltyAmount - the royalty payment amount for _salePrice
     */
    function royaltyInfo(uint256 _tokenId, uint256 _salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {IERC721, IERC721Events, IERC721Metadata, IERC721Receiver} from "./interface/IERC721.sol";
import {IERC165} from "../ERC165/interface/IERC165.sol";

abstract contract ERC165 is IERC165 {
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override
        returns (bool)
    {
        return interfaceId == type(IERC165).interfaceId;
    }
}

/**
 * Based on: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/ERC721.sol
 */
contract ERC721 is ERC165, IERC721, IERC721Events {
    mapping(uint256 => address) internal _owners;
    mapping(address => uint256) internal _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override
        returns (bool)
    {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function balanceOf(address owner)
        public
        view
        virtual
        override
        returns (uint256)
    {
        require(
            owner != address(0),
            "ERC721: balance query for the zero address"
        );
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view virtual returns (address) {
        address owner = _owners[tokenId];
        require(
            owner != address(0),
            "ERC721: owner query for nonexistent token"
        );
        return owner;
    }

    /**
     * @dev Base URI for computing {tokenURI}. Empty by default, can be overriden
     * in child contracts.
     */
    function _baseURI() internal view virtual returns (string memory) {
        return "";
    }

    function approve(address to, uint256 tokenId) public virtual override {
        address owner = ownerOf(tokenId);
        require(to != owner, "ERC721: approval to current owner");

        require(
            msg.sender == owner || isApprovedForAll(owner, msg.sender),
            "ERC721: approve caller is not owner nor approved for all"
        );

        _approve(to, tokenId);
    }

    function getApproved(uint256 tokenId)
        public
        view
        virtual
        override
        returns (address)
    {
        require(
            _exists(tokenId),
            "ERC721: approved query for nonexistent token"
        );

        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved)
        public
        virtual
        override
    {
        require(operator != msg.sender, "ERC721: approve to caller");

        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator)
        public
        view
        virtual
        override
        returns (bool)
    {
        return _operatorApprovals[owner][operator];
    }

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override {
        //solhint-disable-next-line max-line-length
        require(
            _isApprovedOrOwner(msg.sender, tokenId),
            "ERC721: transfer caller is not owner nor approved"
        );

        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) public virtual override {
        require(
            _isApprovedOrOwner(msg.sender, tokenId),
            "ERC721: transfer caller is not owner nor approved"
        );
        _safeTransfer(from, to, tokenId, _data);
    }

    function _safeTransfer(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) internal virtual {
        _transfer(from, to, tokenId);
        require(
            _checkOnERC721Received(from, to, tokenId, _data),
            "ERC721: transfer to non ERC721Receiver implementer"
        );
    }

    function _exists(uint256 tokenId) internal view virtual returns (bool) {
        return _owners[tokenId] != address(0);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId)
        internal
        view
        virtual
        returns (bool)
    {
        require(
            _exists(tokenId),
            "ERC721: operator query for nonexistent token"
        );
        address owner = ownerOf(tokenId);
        return (spender == owner ||
            getApproved(tokenId) == spender ||
            isApprovedForAll(owner, spender));
    }

    function _safeMint(address to, uint256 tokenId) internal virtual {
        _safeMint(to, tokenId, "");
    }

    function _safeMint(
        address to,
        uint256 tokenId,
        bytes memory _data
    ) internal virtual {
        _mint(to, tokenId);
        require(
            _checkOnERC721Received(address(0), to, tokenId, _data),
            "ERC721: transfer to non ERC721Receiver implementer"
        );
    }

    function _mint(address to, uint256 tokenId) internal virtual {
        require(to != address(0), "ERC721: mint to the zero address");
        require(!_exists(tokenId), "ERC721: token already minted");

        _beforeTokenTransfer(address(0), to, tokenId);

        _balances[to] += 1;
        _owners[tokenId] = to;

        emit Transfer(address(0), to, tokenId);
    }

    function _burn(uint256 tokenId) internal virtual {
        address owner = ownerOf(tokenId);

        _beforeTokenTransfer(owner, address(0), tokenId);

        // Clear approvals
        _approve(address(0), tokenId);

        _balances[owner] -= 1;
        delete _owners[tokenId];

        emit Transfer(owner, address(0), tokenId);
    }

    function _transfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual {
        require(
            ownerOf(tokenId) == from,
            "ERC721: transfer of token that is not own"
        );
        require(to != address(0), "ERC721: transfer to the zero address");

        _beforeTokenTransfer(from, to, tokenId);

        // Clear approvals from the previous owner
        _approve(address(0), tokenId);

        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;

        emit Transfer(from, to, tokenId);
    }

    function _approve(address to, uint256 tokenId) internal virtual {
        _tokenApprovals[tokenId] = to;
        emit Approval(ownerOf(tokenId), to, tokenId);
    }

    function _checkOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) private returns (bool) {
        if (isContract(to)) {
            try
                IERC721Receiver(to).onERC721Received(
                    msg.sender,
                    from,
                    tokenId,
                    _data
                )
            returns (bytes4 retval) {
                return retval == IERC721Receiver(to).onERC721Received.selector;
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert(
                        "ERC721: transfer to non ERC721Receiver implementer"
                    );
                } else {
                    // solhint-disable-next-line no-inline-assembly
                    assembly {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
        } else {
            return true;
        }
    }

    // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/7f6a1666fac8ecff5dd467d0938069bc221ea9e0/contracts/utils/Address.sol
    function isContract(address account) internal view returns (bool) {
        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual {}
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IERC721 {
    function balanceOf(address owner) external view returns (uint256 balance);

    function ownerOf(uint256 tokenId) external view returns (address owner);

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function approve(address to, uint256 tokenId) external;

    function getApproved(uint256 tokenId)
        external
        view
        returns (address operator);

    function setApprovalForAll(address operator, bool _approved) external;

    function isApprovedForAll(address owner, address operator)
        external
        view
        returns (bool);

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) external;
}

interface IERC721Events {
    event Transfer(
        address indexed from,
        address indexed to,
        uint256 indexed tokenId
    );
    event Approval(
        address indexed owner,
        address indexed approved,
        uint256 indexed tokenId
    );
    event ApprovalForAll(
        address indexed owner,
        address indexed operator,
        bool approved
    );
}

interface IERC721Metadata {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function tokenURI(uint256 tokenId) external view returns (string memory);
}

interface IERC721Burnable is IERC721 {
    function burn(uint256 tokenId) external;
}

interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

interface IERC721Royalties {
    function getFeeRecipients(uint256 id)
        external
        view
        returns (address payable[] memory);

    function getFeeBps(uint256 id) external view returns (uint256[] memory);
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IOwnableEvents {
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
}

contract Ownable is IOwnableEvents {
    address public owner;
    address private nextOwner;

    // modifiers

    modifier onlyOwner() {
        require(isOwner(), "caller is not the owner.");
        _;
    }

    modifier onlyNextOwner() {
        require(isNextOwner(), "current owner must set caller as next owner.");
        _;
    }

    /**
     * @dev Initialize contract by setting transaction submitter as initial owner.
     */
    constructor(address owner_) {
        _setInitialOwner(owner_);
    }

    /**
     * @dev Initiate ownership transfer by setting nextOwner.
     */
    function transferOwnership(address nextOwner_) external onlyOwner {
        require(nextOwner_ != address(0), "Next owner is the zero address.");

        nextOwner = nextOwner_;
    }

    /**
     * @dev Cancel ownership transfer by deleting nextOwner.
     */
    function cancelOwnershipTransfer() external onlyOwner {
        delete nextOwner;
    }

    /**
     * @dev Accepts ownership transfer by setting owner.
     */
    function acceptOwnership() external onlyNextOwner {
        delete nextOwner;

        owner = msg.sender;

        emit OwnershipTransferred(owner, msg.sender);
    }

    /**
     * @dev Renounce ownership by setting owner to zero address.
     */
    function renounceOwnership() external onlyOwner {
        _renounceOwnership();
    }

    /**
     * @dev Returns true if the caller is the current owner.
     */
    function isOwner() public view returns (bool) {
        return msg.sender == owner;
    }

    /**
     * @dev Returns true if the caller is the next owner.
     */
    function isNextOwner() public view returns (bool) {
        return msg.sender == nextOwner;
    }

    function _setOwner(address previousOwner, address newOwner) internal {
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, owner);
    }

    function _setInitialOwner(address newOwner) internal {
        owner = newOwner;
        emit OwnershipTransferred(address(0), newOwner);
    }

    function _renounceOwnership() internal {
        emit OwnershipTransferred(owner, address(0));

        owner = address(0);
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

contract Reentrancy {
    // ============ Constants ============

    uint256 internal constant REENTRANCY_NOT_ENTERED = 1;
    uint256 internal constant REENTRANCY_ENTERED = 2;

    // ============ Mutable Storage ============

    uint256 internal reentrancyStatus;

    // ============ Modifiers ============

    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(reentrancyStatus != REENTRANCY_ENTERED, "Reentrant call");
        // Any calls to nonReentrant after this point will fail
        reentrancyStatus = REENTRANCY_ENTERED;
        _;
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip2200)
        reentrancyStatus = REENTRANCY_NOT_ENTERED;
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IObservability {
    function emitTransferEvent(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function emitWritingEditionPurchased(
        uint256 tokenId,
        address recipient,
        uint256 price,
        string memory message
    ) external;

    function emitRoyaltyChange(
        address oldRoyaltyRecipient,
        uint256 oldRoyaltyBPS,
        address newRoyaltyRecipient,
        uint256 newRoyaltyBPS
    ) external;

    function emitRendererSet(address renderer) external;

    function emitWritingEditionLimitSet(uint256 oldLimit, uint256 newLimit)
        external;

    function emitFundingRecipientSet(address fundingRecipient) external;

    function emitPriceSet(uint256 price) external;
}

interface IObservabilityEvents {
    event WritingEditionPurchased(
        address indexed clone,
        uint256 tokenId,
        address indexed recipient,
        uint256 price,
        string message
    );

    event Transfer(
        address indexed clone,
        address indexed from,
        address indexed to,
        uint256 tokenId
    );

    event RoyaltyChange(
        address indexed clone,
        address indexed oldRoyaltyRecipient,
        uint256 oldRoyaltyBPS,
        address indexed newRoyaltyRecipient,
        uint256 newRoyaltyBPS
    );

    event RendererSet(address indexed clone, address indexed renderer);

    event WritingEditionLimitSet(
        address indexed clone,
        uint256 oldLimit,
        uint256 newLimit
    );

    event PriceSet(address indexed clone, uint256 price);

    event FundingRecipientSet(address indexed clone, address fundingRecipient);
}

/**
 * @title Observability
 * @author MirrorXYZ
 */
contract Observability is IObservability, IObservabilityEvents {
    function emitWritingEditionPurchased(
        uint256 tokenId,
        address recipient,
        uint256 price,
        string memory message
    ) external override {
        emit WritingEditionPurchased(
            msg.sender,
            tokenId,
            recipient,
            price,
            message
        );
    }

    function emitTransferEvent(
        address from,
        address to,
        uint256 tokenId
    ) external override {
        emit Transfer(msg.sender, from, to, tokenId);
    }

    function emitRoyaltyChange(
        address oldRoyaltyRecipient,
        uint256 oldRoyaltyBPS,
        address newRoyaltyRecipient,
        uint256 newRoyaltyBPS
    ) external override {
        emit RoyaltyChange(
            msg.sender,
            oldRoyaltyRecipient,
            oldRoyaltyBPS,
            newRoyaltyRecipient,
            newRoyaltyBPS
        );
    }

    function emitRendererSet(address renderer) external override {
        emit RendererSet(msg.sender, renderer);
    }

    function emitWritingEditionLimitSet(uint256 oldLimit, uint256 newLimit)
        external
        override
    {
        emit WritingEditionLimitSet(msg.sender, oldLimit, newLimit);
    }

    function emitPriceSet(uint256 price) external override {
        emit PriceSet(msg.sender, price);
    }

    function emitFundingRecipientSet(address fundingRecipient)
        external
        override
    {
        emit FundingRecipientSet(msg.sender, fundingRecipient);
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IRenderer {
    function tokenURI(uint256 tokenId) external view returns (string calldata);

    function contractURI() external view returns (string calldata);
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IMirrorTreasury {
    function transferFunds(address payable to, uint256 value) external;

    function transferERC20(
        address token,
        address to,
        uint256 value
    ) external;

    function contributeWithTributary(address tributary) external payable;

    function contribute(uint256 amount) external payable;
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface ITreasuryConfig {
    function treasury() external returns (address payable);

    function distributionModel() external returns (address);
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {Ownable} from "../lib/Ownable.sol";
import {Reentrancy} from "../lib/Reentrancy.sol";
import {ERC721, IERC721, IERC165} from "../lib/ERC721/ERC721.sol";
import {IERC721Metadata} from "../lib/ERC721/interface/IERC721.sol";
import {IERC2981} from "../lib/ERC2981/interface/IERC2981.sol";
import {IWritingEditions, IWritingEditionEvents} from "./interface/IWritingEditions.sol";
import {IObservability, IObservabilityEvents} from "../observability/Observability.sol";

import {IRenderer} from "../renderer/interface/IRenderer.sol";

import {ITreasuryConfig} from "../treasury/interface/ITreasuryConfig.sol";
import {IMirrorTreasury} from "../treasury/interface/IMirrorTreasury.sol";
import {IMirrorFeeConfiguration} from "../fee-configuration/MirrorFeeConfiguration.sol";

import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

/**
 * @title WritingEditions
 * Early version of writing editions. Please DO NOT use.
 * @author MirrorXYZ
 */
contract WritingEditions is
    Ownable,
    Reentrancy,
    ERC721,
    IERC721Metadata,
    IERC2981,
    IWritingEditions,
    IWritingEditionEvents,
    IObservabilityEvents
{
    // ============ Deployment ============

    /// @notice Address that deploys and initializes clones.
    address public immutable override factory;

    // ============ Configuration ============

    /// @notice Address for Mirror fee configuration.
    address public immutable override feeConfig;

    /// @notice Address for Mirror treasury configuration.
    address public immutable override treasuryConfig;

    /// @notice Address for Mirror's observability contract.
    address public immutable o11yContract;

    // ============ ERC721 Metadata ============

    /// @notice Token name.
    string public override name;

    /// @notice Token symbol.
    string public override symbol;

    // ============ Token Data ============

    /// @notice Token description.
    string public override description;

    /// @notice Total supply of editions. Used to calculate next tokenId.
    uint256 public override totalSupply;

    /// @notice Token text content, stored in Arweave.
    string public override contentURI;

    /// @notice Token image content, stored in IPFS.
    string public override imageURI;

    /// @notice Token contract metadata stored in IPFS.
    string internal _contractURI;

    /// @notice Token price, set by the owner.
    uint256 public override price;

    /// @notice Token limit, set by the owner.
    uint256 public override limit;

    /// @notice Account that will receive funds from sales.
    address public override fundingRecipient;

    // ============ Fees ============
    uint16 public override fee;

    // ============ Royalty Info (ERC2981) ============

    /// @notice Account that will receive royalties.
    address public override royaltyRecipient;

    /// @notice Royalty basis points.
    uint256 public override royaltyBPS;

    // ============ Rendering ============

    /// @notice Address for a rendering contract, if set calls to
    /// `tokenURI(uint256)` are forwarded to this address.
    address public override renderer;

    // ============ Constructor ============

    constructor(
        address factory_,
        address feeConfig_,
        address treasuryConfig_,
        address o11yContract_
    ) Ownable(address(0)) {
        factory = factory_;
        feeConfig = feeConfig_;
        treasuryConfig = treasuryConfig_;
        o11yContract = o11yContract_;
    }

    // ============ Initializing ============

    function initialize(
        address owner_,
        WritingEdition memory edition,
        address renderer_,
        address tokenRecipient,
        string memory message
    ) external payable override {
        require(msg.sender == factory, "unauthorized caller");

        // Store ERC721 metadata.
        name = edition.name;
        symbol = edition.symbol;

        // Store edition data.
        description = edition.description;
        imageURI = edition.imageURI;
        contentURI = edition.contentURI;
        _contractURI = edition.contractURI;
        price = edition.price;
        limit = edition.limit;
        fundingRecipient = edition.fundingRecipient;

        // Store fee.
        _setFee(edition.fee);

        // Store owner.
        _setInitialOwner(owner_);

        // Mint initial token to recipient, assuming
        // the correct value was sent through the factory
        if (tokenRecipient != address(0)) {
            _purchase(tokenRecipient, message);
        }

        // Store renderer.
        renderer = renderer_;
    }

    // ============ View Functions ============

    /// @notice Helper function to get owners for many tokenIds.
    /// @dev Could revert if `tokenIds` is too long.
    // @param tokenIds a list of token-ids to check ownership of.
    // @return owners a list of token-id owners, address(0) if token is not minted
    function ownerOf(uint256[] memory tokenIds)
        external
        view
        override
        returns (address[] memory owners)
    {
        owners = new address[](tokenIds.length);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            owners[i] = _owners[tokenIds[i]];
        }

        return owners;
    }

    // ============ Funding Recipient ============

    /// @notice Set the price
    function setFundingRecipient(address fundingRecipient_)
        external
        override
        onlyOwner
    {
        fundingRecipient = fundingRecipient_;

        IObservability(o11yContract).emitFundingRecipientSet(
            // fundingRecipient
            fundingRecipient_
        );
    }

    // ============ Price ============

    /// @notice Set the price
    function setPrice(uint256 price_) external override onlyOwner {
        price = price_;

        IObservability(o11yContract).emitPriceSet(
            // price
            price_
        );
    }

    // ============ Purchase ============

    /// @notice Purchase a token.
    /// @param recipient the account to receive the token
    function purchase(address recipient, string memory message)
        external
        payable
        override
        nonReentrant
        returns (uint256 tokenId)
    {
        require(msg.value == price, "incorrect value");

        return _purchase(recipient, message);
    }

    /// @notice Purchase a token.
    /// @param recipient the account to receive the token
    function purchaseThroughFactory(address recipient, string memory message)
        external
        payable
        override
        nonReentrant
        returns (uint256 tokenId)
    {
        require(msg.value == price, "incorrect value");

        require(msg.sender == factory, "unauthorized");

        return _purchase(recipient, message);
    }

    // ============ Mint ============

    /// @notice Mint an edition
    /// @dev throws if called by a non-owner
    /// @param recipient the account to receive the edition
    function mint(address recipient)
        external
        override
        onlyOwner
        returns (uint256 tokenId)
    {
        tokenId = _getTokenIdAndMint(recipient);
    }

    // ============ Limit ============

    /// @notice Allows the owner to set a global limit on the total supply
    /// @dev throws if attempting to increase the limit
    function setLimit(uint256 newLimit) external override onlyOwner {
        // Enforce that the limit should only ever decrease once set.
        require(
            newLimit >= totalSupply && (limit == 0 || newLimit < limit),
            "limit must be < than current limit"
        );

        // Announce the change in limit.
        IObservability(o11yContract).emitWritingEditionLimitSet(
            // oldLimit
            limit,
            // newLimit
            newLimit
        );

        // Update the limit.
        limit = newLimit;
    }

    // ============ ERC2981 Methods ============

    /// @notice Called with the sale price to determine how much royalty
    //  is owed and to whom
    /// @param _tokenId - the NFT asset queried for royalty information
    /// @param _salePrice - the sale price of the NFT asset specified by _tokenId
    /// @return receiver - address of who should be sent the royalty payment
    /// @return royaltyAmount - the royalty payment amount for _salePrice
    function royaltyInfo(uint256 _tokenId, uint256 _salePrice)
        external
        view
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        receiver = _royaltyRecipient();

        royaltyAmount = (_salePrice * _royaltyBPS()) / 10_000;
    }

    /// @param royaltyRecipient_ the address that will receive royalties
    /// @param royaltyBPS_ the royalty amount in basis points (bps)
    function setRoyaltyInfo(
        address payable royaltyRecipient_,
        uint256 royaltyBPS_
    ) external override onlyOwner {
        require(
            royaltyBPS_ <= 10_000,
            "bps must be less than or equal to 10,000"
        );

        IObservability(o11yContract).emitRoyaltyChange(
            // oldRoyaltyRecipient
            _royaltyRecipient(),
            // oldRoyaltyBPS
            _royaltyBPS(),
            // newRoyaltyRecipient
            royaltyRecipient_,
            // newRoyaltyBPS
            royaltyBPS_
        );

        royaltyRecipient = royaltyRecipient_;
        royaltyBPS = royaltyBPS_;
    }

    // ============ Rendering Methods ============

    /// @notice Set the renderer address
    /// @dev Throws if renderer is not the zero address
    function setRenderer(address renderer_) external override onlyOwner {
        require(renderer == address(0), "renderer already set");

        renderer = renderer_;

        IObservability(o11yContract).emitRendererSet(
            //renderer
            renderer_
        );
    }

    /// @notice Get contract metadata
    /// @dev If a renderer is set, return the renderer's metadata
    function contractURI() external view override returns (string memory) {
        if (renderer != address(0)) {
            try IRenderer(renderer).contractURI() returns (
                string memory result
            ) {
                return result;
            } catch {
                // Fallback if the renderer does not implement contractURI
                return string(abi.encodePacked("ipfs://", _contractURI));
            }
        }

        return string(abi.encodePacked("ipfs://", _contractURI));
    }

    /// @notice Get `tokenId` URI or data
    /// @dev If a renderer is set, call renderer's tokenURI
    /// @param tokenId The tokenId used to request data
    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        require(_exists(tokenId), "ERC721: query for nonexistent token");

        if (renderer != address(0)) {
            return IRenderer(renderer).tokenURI(tokenId);
        }

        bytes memory editionNumber;
        if (limit != 0) {
            editionNumber = abi.encodePacked("/", Strings.toString(limit));
        }

        string memory json = Base64.encode(
            bytes(
                string(
                    abi.encodePacked(
                        '{"name": "',
                        name,
                        " ",
                        Strings.toString(tokenId),
                        editionNumber,
                        '", "description": "',
                        string(description),
                        '", "content": "ar://',
                        string(contentURI),
                        '", "image": "ipfs://',
                        string(imageURI),
                        '", "attributes":[{ "trait_type": "Serial", "value": ',
                        Strings.toString(tokenId),
                        " }] }"
                    )
                )
            )
        );
        return string(abi.encodePacked("data:application/json;base64,", json));
    }

    // ============ IERC165 Method ============

    function supportsInterface(bytes4 interfaceId)
        public
        pure
        override
        returns (bool)
    {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId ||
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC2981).interfaceId;
    }

    // ============ Internal Methods ============

    /// @dev Emit a transfer event from observability contract.
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual override {
        IObservability(o11yContract).emitTransferEvent(from, to, tokenId);
    }

    function _royaltyRecipient() internal view returns (address) {
        return
            royaltyRecipient == address(0)
                ? fundingRecipient
                : royaltyRecipient;
    }

    /// @dev The ternary expression below prevents from returning 0 as the
    /// royalty amount. To turn off royalties, we make the assumption that
    /// if the royaltyRecipient is set to address(0), the marketplace code
    /// will ignore the royalty amount.
    function _royaltyBPS() internal view returns (uint256) {
        return royaltyBPS == 0 ? 1000 : royaltyBPS;
    }

    /// @dev Mints token and emits purchase event
    function _purchase(address tokenRecipient, string memory message)
        internal
        returns (uint256 tokenId)
    {
        // Mint token, and get a tokenId.
        tokenId = _getTokenIdAndMint(tokenRecipient);

        // Emit event through observability contract.
        IObservability(o11yContract).emitWritingEditionPurchased(
            // tokenId
            tokenId,
            // recipient
            tokenRecipient,
            // price
            price,
            // messgae
            message
        );

        _withdraw(fundingRecipient, msg.value);
    }

    function _withdraw(address fundsRecipient, uint256 amount) internal {
        if (IMirrorFeeConfiguration(feeConfig).on()) {
            // Calculate the fee on the current balance, using the fee percentage.
            uint256 feeAmount = _feeAmount(amount, fee);

            // If the fee is not zero, attempt to send it to the treasury.
            // If the treasuy is not set, do not pay the fee.
            address treasury = ITreasuryConfig(treasuryConfig).treasury();
            if (feeAmount != 0 && treasury != address(0)) {
                _sendEther(payable(treasury), feeAmount);

                // Transfer the remaining amount to the recipient.
                _sendEther(payable(fundsRecipient), amount - feeAmount);
            } else {
                _sendEther(payable(fundsRecipient), amount);
            }
        } else {
            _sendEther(payable(fundsRecipient), amount);
        }
    }

    function _sendEther(address payable recipient_, uint256 amount) internal {
        // Ensure sufficient balance.
        require(address(this).balance >= amount, "insufficient balance");
        // Send the value.
        (bool success, ) = recipient_.call{value: amount, gas: gasleft()}("");
        require(success, "recipient reverted");
    }

    function _feeAmount(uint256 amount, uint16 fee_)
        internal
        pure
        returns (uint256)
    {
        return amount >= 10_000 ? (amount / 10_000) * fee_ : 0;
    }

    // @dev If fee is invalid, default to minimum fee
    function _setFee(uint16 newFee) internal {
        fee = IMirrorFeeConfiguration(feeConfig).valid(newFee)
            ? newFee
            : IMirrorFeeConfiguration(feeConfig).minimumFee();
    }

    /// @dev Mints and returns tokenId
    function _getTokenIdAndMint(address recipient)
        internal
        returns (uint256 tokenId)
    {
        // Increment totalSupply to get next id and store tokenId.
        tokenId = ++totalSupply;

        // check that there are still tokens available to purchase
        // zero and max uint256 represent infinite minting
        require(
            limit == 0 || limit == type(uint256).max || tokenId < limit + 1,
            "sold out"
        );

        // mint a new token for the recipient, using the `tokenId`.
        _mint(recipient, tokenId);
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "openzeppelin-contracts/contracts/proxy/Clones.sol";
import "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

import {Reentrancy} from "../lib/Reentrancy.sol";
import {WritingEditions} from "./WritingEditions.sol";
import {IObservabilityEvents} from "../observability/Observability.sol";
import {IWritingEditionsFactory, IWritingEditionsFactoryEvents} from "./interface/IWritingEditionsFactory.sol";
import {IWritingEditions} from "./interface/IWritingEditions.sol";
import {IERC1271} from "../lib/ERC1271/interface/IERC1271.sol";

interface ITributaryRegistry {
    function registerTributary(address producer, address tributary) external;
}

/**
 * @title WritingEditionsFactory
 * @notice The WritingEditionsFactory contract is used to deploy writing-edition clones.
 * Early version of writing editions. Please DO NOT use.
 * @author MirrorXYZ
 */
contract WritingEditionsFactory is
    Reentrancy,
    IWritingEditionsFactoryEvents,
    IWritingEditionsFactory,
    IObservabilityEvents
{
    /// @notice Writing edition implementation
    address public immutable implementation;

    /// @notice Mirror tributary registry
    address public immutable tributaryRegistry;

    // ============ Deployments ============

    /// @dev Store when a salt is used.
    mapping(bytes32 => bool) public salts;

    /// @dev Contract/domain separator for generating a salt.
    bytes32 public immutable override DOMAIN_SEPARATOR;

    /// @dev Create function separator for generating a salt.
    bytes32 public constant override CREATE_TYPEHASH =
        keccak256(
            "Create(address owner,bytes32 salt,uint256 limit,uint256 price,address fundingRecipient,address renderer,uint256 nonce,uint16 fee)"
        );

    /// @dev Used to verify smart contract signatures (ERC1271)
    bytes4 internal constant MAGIC_VALUE =
        bytes4(keccak256("isValidSignature(bytes32,bytes)"));

    // ============ Constructor ============

    constructor(
        address tributaryRegistry_,
        address feeConfig_,
        address treasuryConfig_,
        address o11yContract_
    ) {
        implementation = address(
            new WritingEditions(
                address(this),
                feeConfig_,
                treasuryConfig_,
                o11yContract_
            )
        );

        tributaryRegistry = tributaryRegistry_;

        // generate domain separator
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    // ======== View functions =========

    /// @notice Generates the address that a clone will be deployed to.
    function predictDeterministicAddress(address implementation_, bytes32 salt)
        external
        view
        override
        returns (address)
    {
        return
            Clones.predictDeterministicAddress(
                implementation_,
                salt,
                address(this)
            );
    }

    /// @notice Generates the salt parameter for `owner_` to sign. The signature
    /// and parameters can be used to deploy a clone through `createWithSignature`.
    function getSalt(
        address owner_,
        IWritingEditions.WritingEdition memory edition_
    ) external view returns (bytes32) {
        return _getSalt(owner_, edition_);
    }

    function isValid(
        address owner_,
        bytes32 salt,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external view returns (bool) {
        return _isValid(owner_, salt, v, r, s);
    }

    // ======== Deployment functions =========

    // @notice Deploy a new writing edition clone with the sender as the owner.
    function create(IWritingEditions.WritingEdition memory edition_)
        external
        override
        returns (address clone)
    {
        clone = _deployCloneAndInitialize(msg.sender, edition_, address(0), "");
    }

    /// @dev Deploy a new writing edition clone with a signature provided by `owner_`.
    function createWithSignature(
        address owner_,
        IWritingEditions.WritingEdition memory edition_,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address tokenRecipient,
        string memory message
    ) external payable override nonReentrant returns (address clone) {
        // Assert enough ETH was sent to purchase the token
        require(msg.value == edition_.price, "incorrect value");

        // Generate salt from parameters
        bytes32 salt = _getSalt(owner_, edition_);

        // If the clone has been deployed, purchase instead of deploying
        if (salts[salt]) {
            clone = Clones.predictDeterministicAddress(
                implementation,
                keccak256(
                    abi.encode(
                        owner_,
                        edition_.name,
                        edition_.symbol,
                        edition_.nonce
                    )
                ),
                address(this)
            );

            require(clone.code.length > 0, "invalid clone address");

            IWritingEditions(clone).purchaseThroughFactory{value: msg.value}(
                tokenRecipient,
                message
            );
        } else {
            // Assert the signature is valid
            require(
                _isValid(owner_, salt, v, r, s),
                "invalid or unable to verify signature"
            );

            clone = _deployCloneAndInitialize(
                owner_,
                edition_,
                tokenRecipient,
                message
            );

            salts[salt] = true;
        }
    }

    // ======== Purchase functions =========

    /// @notice Purchase an edition through the factory
    function purchaseThroughFactory(
        address clone,
        address tokenRecipient,
        string memory message
    ) external payable returns (uint256 tokenId) {
        return
            IWritingEditions(clone).purchaseThroughFactory{value: msg.value}(
                tokenRecipient,
                message
            );
    }

    // ============ Internal functions ============

    function _isValid(
        address owner_,
        bytes32 salt,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view returns (bool) {
        require(owner_ != address(0), "cannot validate");

        // If the owner is a contract, attempt to validate the
        // signature using EIP-1271.
        if (owner_.code.length != 0) {
            bytes memory signature = abi.encodePacked(r, s, v);

            try IERC1271(owner_).isValidSignature(salt, signature) returns (
                bytes4 magicValue
            ) {
                return MAGIC_VALUE == magicValue;
            } catch {
                return false;
            }
        }

        address recoveredAddress = ECDSA.recover(salt, v, r, s);

        return recoveredAddress == owner_;
    }

    function _getSalt(
        address owner_,
        IWritingEditions.WritingEdition memory edition_
    ) internal view returns (bytes32) {
        return
            ECDSA.toTypedDataHash(
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        CREATE_TYPEHASH,
                        owner_,
                        keccak256(
                            abi.encodePacked(
                                edition_.name,
                                edition_.symbol,
                                edition_.description,
                                edition_.imageURI,
                                edition_.contentURI,
                                edition_.contractURI
                            )
                        ),
                        edition_.limit,
                        edition_.price,
                        edition_.fundingRecipient,
                        edition_.renderer,
                        edition_.nonce,
                        edition_.fee
                    )
                )
            );
    }

    /// @dev Deploys a clone and calls the initialize function. Additionally,
    /// this function calls `registerTributary` on the tributary registry, if
    /// one is set.
    function _deployCloneAndInitialize(
        address owner_,
        IWritingEditions.WritingEdition memory edition_,
        address tokenRecipient,
        string memory message
    ) internal returns (address clone) {
        require(
            edition_.fundingRecipient != address(0),
            "must specify recipient"
        );

        clone = Clones.cloneDeterministic(
            implementation,
            keccak256(
                abi.encode(
                    owner_,
                    edition_.name,
                    edition_.symbol,
                    edition_.nonce
                )
            )
        );

        IWritingEditions(clone).initialize{value: msg.value}(
            owner_,
            edition_,
            edition_.renderer,
            tokenRecipient,
            message
        );

        emit EditionsDeployed(owner_, clone, implementation);

        if (tributaryRegistry != address(0)) {
            ITributaryRegistry(tributaryRegistry).registerTributary(
                clone,
                edition_.fundingRecipient
            );
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IWritingEditionEvents {
    event RoyaltyChange(
        address indexed oldRoyaltyRecipient,
        uint256 oldRoyaltyBPS,
        address indexed newRoyaltyRecipient,
        uint256 newRoyaltyBPS
    );

    event RendererSet(address indexed renderer);

    event WritingEditionLimitSet(uint256 oldLimit, uint256 newLimit);

    event PriceSet(uint256 price);
}

interface IWritingEditions {
    struct WritingEdition {
        string name;
        string symbol;
        string description;
        string imageURI;
        string contractURI;
        string contentURI;
        uint256 price;
        uint256 limit;
        address fundingRecipient;
        address renderer;
        uint256 nonce;
        uint16 fee;
    }

    // ============ Authorization ============

    function factory() external returns (address);

    // ============ Fee Configuration ============

    function feeConfig() external returns (address);

    function treasuryConfig() external returns (address);

    // ============ Edition Data ============

    function description() external view returns (string memory);

    function totalSupply() external view returns (uint256);

    function price() external view returns (uint256);

    function limit() external view returns (uint256);

    function contentURI() external view returns (string memory);

    function imageURI() external view returns (string memory);

    // ============ View Functions ============

    function ownerOf(uint256[] memory tokenIds)
        external
        view
        returns (address[] memory owners);

    // ============ Funding Recipient ============

    function fundingRecipient() external returns (address);

    // ============ Fees ============
    function fee() external returns (uint16);

    // ============ Royalty Info (ERC2981) ============

    function royaltyRecipient() external returns (address);

    function royaltyBPS() external returns (uint256);

    // ============ Rendering ============

    function renderer() external view returns (address);

    // ============ Initializing ============

    function initialize(
        address owner_,
        WritingEdition memory edition,
        address renderer_,
        address recipient,
        string memory message
    ) external payable;

    // ============ Funding Recipient ============

    function setFundingRecipient(address fundingRecipient_) external;

    // ============ Price ============

    function setPrice(uint256 price_) external;

    // ============ Purchase ============

    function purchase(address recipient, string memory message)
        external
        payable
        returns (uint256 tokenId);

    function purchaseThroughFactory(address recipient, string memory message)
        external
        payable
        returns (uint256 tokenId);

    // ============ Minting ============

    function mint(address recipient) external returns (uint256 tokenId);

    function setLimit(uint256 limit_) external;

    // ============ ERC2981 Methods ============

    function setRoyaltyInfo(
        address payable royaltyRecipient_,
        uint256 royaltyPercentage_
    ) external;

    // ============ Rendering Methods ============

    function setRenderer(address renderer_) external;

    function contractURI() external view returns (string memory);
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {IWritingEditions} from "./IWritingEditions.sol";

interface IWritingEditionsFactoryEvents {
    event NewImplementation(
        address indexed oldImplementation,
        address indexed newImplementation
    );

    event EditionsDeployed(
        address indexed owner,
        address indexed clone,
        address indexed implementation
    );
}

interface IWritingEditionsFactory {
    function DOMAIN_SEPARATOR() external returns (bytes32);

    function CREATE_TYPEHASH() external returns (bytes32);

    function getSalt(
        address owner_,
        IWritingEditions.WritingEdition memory edition_
    ) external view returns (bytes32);

    function predictDeterministicAddress(address implementation_, bytes32 salt)
        external
        view
        returns (address);

    function create(IWritingEditions.WritingEdition memory edition_)
        external
        returns (address clone);

    function createWithSignature(
        address owner_,
        IWritingEditions.WritingEdition memory edition_,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address recipient,
        string memory message
    ) external payable returns (address clone);
}