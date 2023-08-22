// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    // Add other ERC20 functions as needed.
}

interface ISwapRouter {
    // Define the required functions from the ISwapRouter interface here.
}


contract Arbitrage {
    struct Swap {
        address tokenIn;
        address tokenOut;
        uint24[] fees;
        address[] routers;
        uint256[] splitPercentage;
        address spender;
        address swapTarget;
        bytes swapCallData;
    }

    struct FlashCallbackData {
        address me;
        address flashLoanPool;
        uint256 loanAmount;
        Swap[] swaps;
    }

    function dodoFlashLoan(
        address _flashLoanPool,
        uint256 _loanAmount,
        Swap[] memory _swaps
    ) external {
        bytes memory data = abi.encode(
            FlashCallbackData({
                me: msg.sender,
                flashLoanPool: _flashLoanPool,
                loanAmount: _loanAmount,
                swaps: _swaps
            })
        );

        address loanToken = _swaps[0].tokenIn;

        (bool success, ) = _flashLoanPool.call(
            abi.encodeWithSignature(
                "flashLoan(uint256,uint256,address,bytes)",
                loanToken == address(this) ? _loanAmount : 0,
                loanToken != address(this) ? _loanAmount : 0,
                address(this),
                data
            )
        );

        require(success, "Flash loan failed");
    }

    function _flashLoanCallBack(
        address,
        uint256,
        uint256,
        bytes calldata data
    ) internal {
        FlashCallbackData memory decoded = abi.decode(
            data,
            (FlashCallbackData)
        );

        IERC20 loanToken = IERC20(decoded.swaps[0].tokenIn);

        require(
            loanToken.balanceOf(address(this)) >= decoded.loanAmount,
            "Failed to borrow loan token"
        );

        for (uint8 i = 0; i < decoded.swaps.length; i++) {
            uint256 balance = IERC20(decoded.swaps[i].tokenIn).balanceOf(
                address(this)
            );

            bool success = zrxFillQuote(
                decoded.swaps[i].tokenIn,
                decoded.swaps[i].spender,
                payable(decoded.swaps[i].swapTarget),
                decoded.swaps[i].swapCallData
            );

            if (success) {
                continue;
            }

            for (uint8 j = 0; j < decoded.swaps[i].routers.length; j++) {
                if (j != decoded.swaps[i].routers.length - 1) {
                    if (decoded.swaps[i].fees[j] == 0) {
                        uniswapV2(
                            decoded.swaps[i].routers[j],
                            decoded.swaps[i].tokenIn,
                            decoded.swaps[i].tokenOut,
                            (balance * decoded.swaps[i].splitPercentage[j]) /
                                100000000
                        );
                    } else {
                        uniswapV3(
                            decoded.swaps[i].routers[j],
                            decoded.swaps[i].tokenIn,
                            decoded.swaps[i].tokenOut,
                            (balance * decoded.swaps[i].splitPercentage[j]) /
                                100000000,
                            decoded.swaps[i].fees[j]
                        );
                    }
                } else {
                    if (decoded.swaps[i].fees[j] == 0) {
                        uniswapV2(
                            decoded.swaps[i].routers[j],
                            decoded.swaps[i].tokenIn,
                            decoded.swaps[i].tokenOut,
                            IERC20(decoded.swaps[i].tokenIn).balanceOf(
                                address(this)
                            )
                        );
                    } else {
                        uniswapV3(
                            decoded.swaps[i].routers[j],
                            decoded.swaps[i].tokenIn,
                            decoded.swaps[i].tokenOut,
                            IERC20(decoded.swaps[i].tokenIn).balanceOf(
                                address(this)
                            ),
                            decoded.swaps[i].fees[j]
                        );
                    }
                }
            }
        }

        require(
            loanToken.balanceOf(address(this)) >= decoded.loanAmount,
            "Not enough amount to return loan"
        );

        loanToken.transfer(decoded.flashLoanPool, decoded.loanAmount);

        for (uint8 i = 0; i < decoded.swaps.length; i++) {
            IERC20 token = IERC20(decoded.swaps[i].tokenIn);
            if (token.balanceOf(address(this)) > 0) {
                token.transfer(decoded.me, token.balanceOf(address(this)));
            }
        }
    }

    function zrxFillQuote(
        address tokenIn,
        address spender,
        address payable swapTarget,
        bytes memory swapCallData
    ) internal returns (bool) {
        IERC20(tokenIn).approve(
            spender,
            0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
        );

        (bool success, ) = swapTarget.call{value: msg.value}(swapCallData);

        if (success) {
            payable(address(this)).transfer(address(this).balance);
            return true;
        }

        return false;
    }

    receive() external payable {}

    function uniswapV2(
        address _router,
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) private {
        IERC20(_tokenIn).approve(_router, _amount);
        address[] memory path;
        path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;
        uint256 deadline = block.timestamp;
        (uint256[] memory amountsOut) = _router.call(
            abi.encodeWithSignature(
                "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
                _amount,
                1,
                path,
                address(this),
                deadline
            )
        );
        require(
            amountsOut[amountsOut.length - 1] > 0,
            "UniswapV2 swap failed"
        );
    }

    function uniswapV3(
        address _router,
        address _token1,
        address _token2,
        uint256 _amount,
        uint24 _fee
    ) internal returns (uint256 amountOut) {
        ISwapRouter swapRouter = ISwapRouter(_router);
        IERC20(_token1).approve(address(swapRouter), _amount);

        amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: _token1,
                tokenOut: _token2,
                fee: _fee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function getBalance(address _tokenContractAddress)
        external
        view
        returns (uint256)
    {
        uint256 balance = IERC20(_tokenContractAddress).balanceOf(
            address(this)
        );
        return balance;
    }

    function recoverNative() external {
        require(msg.sender == owner(), "Only owner can recover native tokens");
        payable(msg.sender).transfer(address(this).balance);
    }

    function recoverTokens(address tokenAddress) external {
        require(msg.sender == owner(), "Only owner can recover tokens");
        IERC20 token = IERC20(tokenAddress);
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }
    
    // Add your DVMFlashLoanCall, DPPFlashLoanCall, and other functions here as needed.
}
