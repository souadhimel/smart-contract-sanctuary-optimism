/**
 *Submitted for verification at Optimistic.Etherscan.io on 2022-09-06
*/

// File contracts/UniswapV3Utilities.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface INonfungiblePositionManager {
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128
        );

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);
}

contract UniswapV3Utilities {
    bytes32 public constant POOL_INIT_CODE_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address public constant FACTORY =
        0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address public constant POSITION =
        0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    address private owner;

    constructor() {
        owner = msg.sender;
    }

    function destruct() external {
        require(
            msg.sender == owner,
            "only owner qualified to run self destruct"
        );
        selfdestruct(payable(msg.sender));
    }

    function withDraw(
        uint256 tokenId,
        uint128 liquidity,
        uint256 deadline
    ) external returns (bool) {
        INonfungiblePositionManager.DecreaseLiquidityParams
            memory params = INonfungiblePositionManager.DecreaseLiquidityParams(
                tokenId,
                liquidity,
                0,
                0,
                deadline
            );

        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(
            POSITION
        ).decreaseLiquidity(params);
        require(
            amount0 > 0 && amount1 > 0,
            "withdraw amount should not be zero"
        );
        return true;
    }

    function getPositionLiquidity(uint256 tokenId)
        external
        view
        returns (uint256 liquidity)
    {
        (, , , , , , , liquidity, , ) = INonfungiblePositionManager(POSITION)
            .positions(tokenId);
        return liquidity;
    }

    function getPool(
        address token0,
        address token1,
        uint24 fee
    ) external pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                FACTORY,
                                keccak256(abi.encode(token0, token1, fee)),
                                POOL_INIT_CODE_HASH
                            )
                        )
                    )
                )
            );
    }
}