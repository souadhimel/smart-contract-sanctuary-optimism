/**
 *Submitted for verification at Optimistic.Etherscan.io on 2022-08-26
*/

// Sources flattened with hardhat v2.9.6 https://hardhat.org

// File @rari-capital/solmate/src/auth/[email protected]

// -License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

/// @notice Provides a flexible and updatable auth pattern which is completely separate from application logic.
/// @author Solmate (https://github.com/Rari-Capital/solmate/blob/main/src/auth/Auth.sol)
/// @author Modified from Dappsys (https://github.com/dapphub/ds-auth/blob/master/src/auth.sol)
abstract contract Auth {
    event OwnerUpdated(address indexed user, address indexed newOwner);

    event AuthorityUpdated(address indexed user, Authority indexed newAuthority);

    address public owner;

    Authority public authority;

    constructor(address _owner, Authority _authority) {
        owner = _owner;
        authority = _authority;

        emit OwnerUpdated(msg.sender, _owner);
        emit AuthorityUpdated(msg.sender, _authority);
    }

    modifier requiresAuth() virtual {
        require(isAuthorized(msg.sender, msg.sig), "UNAUTHORIZED");

        _;
    }

    function isAuthorized(address user, bytes4 functionSig) internal view virtual returns (bool) {
        Authority auth = authority; // Memoizing authority saves us a warm SLOAD, around 100 gas.

        // Checking if the caller is the owner only after calling the authority saves gas in most cases, but be
        // aware that this makes protected functions uncallable even to the owner if the authority is out of order.
        return (address(auth) != address(0) && auth.canCall(user, address(this), functionSig)) || user == owner;
    }

    function setAuthority(Authority newAuthority) public virtual {
        // We check if the caller is the owner first because we want to ensure they can
        // always swap out the authority even if it's reverting or using up a lot of gas.
        require(msg.sender == owner || authority.canCall(msg.sender, address(this), msg.sig));

        authority = newAuthority;

        emit AuthorityUpdated(msg.sender, newAuthority);
    }

    function setOwner(address newOwner) public virtual requiresAuth {
        owner = newOwner;

        emit OwnerUpdated(msg.sender, newOwner);
    }
}

/// @notice A generic interface for a contract which provides authorization data to an Auth instance.
/// @author Solmate (https://github.com/Rari-Capital/solmate/blob/main/src/auth/Auth.sol)
/// @author Modified from Dappsys (https://github.com/dapphub/ds-auth/blob/master/src/auth.sol)
interface Authority {
    function canCall(
        address user,
        address target,
        bytes4 functionSig
    ) external view returns (bool);
}


// File contracts/PolynomialAuthority.sol

// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

contract PolynomialAuthority is Auth, Authority {

    mapping (bytes32 => bool) isAllowed;

    constructor() Auth(msg.sender, Authority(address(0x0))) {}

    function canCall(address user, address target, bytes4 functionSig) public view returns (bool) {
        bytes32 hashCode = keccak256(abi.encode(user, target, functionSig));
        return isAllowed[hashCode];
    }

    function setCapacity(address user, address target, bytes4 functionSig, bool allowed) external requiresAuth {
        bytes32 hashCode = keccak256(abi.encode(user, target, functionSig));
        isAllowed[hashCode] = allowed;
    }

    function setCapacities(address user, bool allowed, address[] memory targets, bytes4[] memory functionSigs) external requiresAuth {
        require(targets.length == functionSigs.length);
        for (uint256 i = 0; i < targets.length; i++) {
            bytes32 hashCode = keccak256(abi.encode(user, targets[i], functionSigs[i]));
            isAllowed[hashCode] = allowed;
        }
    }
}