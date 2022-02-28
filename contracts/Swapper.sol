// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.10;
pragma abicoder v2;

import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';

contract Swapper {
    ISwapRouter public immutable swapRouter;

    constructor(ISwapRouter _swapRouter) {
        swapRouter = _swapRouter;
    }

    // path = abi.encodePacked(DAI, poolFee, USDC, poolFee, WETH9)
    function swapExactInputMultihop(address fromToken, bytes calldata path, uint256 amountIn) external returns (uint256 amountOut) {
        TransferHelper.safeTransferFrom(fromToken, msg.sender, address(this), amountIn);

        TransferHelper.safeApprove(fromToken, address(swapRouter), amountIn);

        ISwapRouter.ExactInputParams memory params =
            ISwapRouter.ExactInputParams({
                path: path,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0
            });

        amountOut = swapRouter.exactInput(params);
    }

    // path = abi.encodePacked(WETH9, poolFee, USDC, poolFee, DAI),
    function swapExactOutputMultihop(address fromToken, bytes calldata path, uint256 amountOut, uint256 amountInMaximum) external returns (uint256 amountIn) {
        TransferHelper.safeTransferFrom(fromToken, msg.sender, address(this), amountInMaximum);

        TransferHelper.safeApprove(fromToken, address(swapRouter), amountInMaximum);
        ISwapRouter.ExactOutputParams memory params =
            ISwapRouter.ExactOutputParams({
                path: path,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: amountInMaximum
            });

        amountIn = swapRouter.exactOutput(params);

        if (amountIn < amountInMaximum) {
            TransferHelper.safeApprove(fromToken, address(swapRouter), 0);
            TransferHelper.safeTransferFrom(fromToken, address(this), msg.sender, amountInMaximum - amountIn);
        }
    }
}