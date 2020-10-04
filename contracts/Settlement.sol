// SPDX-License-Identifier: MIT

pragma solidity =0.6.12;
pragma experimental ABIEncoderV2;

import "@sushiswap/core/contracts/uniswapv2/libraries/SafeMath.sol";
import "@sushiswap/core/contracts/uniswapv2/interfaces/IUniswapV2Factory.sol";
import "@sushiswap/core/contracts/uniswapv2/interfaces/IUniswapV2Pair.sol";
import "./interfaces/IMintable.sol";
import "./mixins/Ownable.sol";
import "./UniswapV2Router02.sol";

contract Settlement is Ownable, UniswapV2Router02 {
    using SafeMathUniswap for uint256;

    IMintable public rewardToken;
    // How many tokens will be rewarded for every ETH value filled (in 10^18)
    uint256 public rewardPerAmountFilled;
    mapping(bytes32 => OrderInfo) public orderInfoOfHash;

    constructor(IMintable _rewardToken, uint256 _rewardPerAmountFilled) public {
        rewardToken = _rewardToken;
        rewardPerAmountFilled = _rewardPerAmountFilled;
    }

    function updateRewardToken(IMintable _rewardToken) public onlyOwner {
        rewardToken = _rewardToken;
    }

    function updateRewardPerAmountFilled(uint256 _rewardPerAmountFilled) public onlyOwner {
        rewardPerAmountFilled = _rewardPerAmountFilled;
    }

    function hashOfOrder(Order memory order) public view returns (bytes32 hash) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        return
            keccak256(
                abi.encodePacked(
                    chainId,
                    address(this),
                    order.maker,
                    order.fromToken,
                    order.toToken,
                    order.amountIn,
                    order.amountOutMin,
                    order.recipient,
                    order.deadline
                )
            );
    }

    function fillOrder(FillOrderArgs memory args) public override returns (uint256 amountOut) {
        bytes32 hash = hashOfOrder(args.order);
        if (!_validateArgs(args, hash)) {
            return 0;
        }

        OrderInfo storage info = orderInfoOfHash[hash];
        if (_updateStatus(args, info) != Status.Fillable) {
            return 0;
        }

        (bool success, bytes memory data) = address(this).call(
            abi.encodeWithSelector(
                this.swapExactTokensForTokens.selector,
                args.amountToFillIn,
                args.order.amountOutMin.mul(args.amountToFillIn) / args.order.amountIn,
                args.path,
                args.order.recipient,
                args.order.deadline,
                new FillOrderArgs[](0)
            )
        );

        if (success) {
            info.filledAmountIn = info.filledAmountIn + args.amountToFillIn;
            if (info.filledAmountIn == args.order.amountIn) {
                info.status = Status.Filled;
            }

            amountOut = abi.decode(data, (uint256));
            _transferReward(args.order.toToken, amountOut);

            emit OrderFilled(hash, args.amountToFillIn, amountOut);
        }
        return 0;
    }

    function _validateArgs(FillOrderArgs memory args, bytes32 hash) internal pure returns (bool) {
        return
            args.order.maker != address(0) &&
            args.order.fromToken != address(0) &&
            args.order.toToken != address(0) &&
            args.order.amountIn != uint256(0) &&
            args.order.amountOutMin != uint256(0) &&
            args.order.deadline != uint256(0) &&
            args.amountToFillIn > 0 &&
            args.path.length > 0 &&
            args.order.fromToken == args.path[0] &&
            args.order.toToken == args.path[args.path.length - 1] &&
            _verify(args.order.maker, hash, args.v, args.r, args.s);
    }

    function _updateStatus(FillOrderArgs memory args, OrderInfo storage info)
        internal
        returns (Status)
    {
        if (info.status == Status.Invalid) {
            info.status = Status.Fillable;
        }
        Status status = info.status;
        if (status == Status.Fillable) {
            if (args.order.deadline < block.timestamp) {
                info.status = Status.Expired;
                return Status.Expired;
            } else if (info.filledAmountIn.add(args.amountToFillIn) > args.order.amountIn) {
                return Status.Invalid;
            } else {
                return Status.Fillable;
            }
        }
        return status;
    }

    function _verify(
        address signer,
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public pure returns (bool) {
        bool verified = signer == ecrecover(hash, v, r, s);
        if (verified) {
            return true;
        } else {
            // Consider it signed by web3.eth_sign
            hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
            return signer == ecrecover(hash, v, r, s);
        }
    }

    function _transferReward(address toToken, uint256 amountOut) internal {
        // 1. Calculates the amount of toToken filled in ETH value (amountFilledInETH)
        // 2. (amountToMint) = (rewardPerAmountFilled) * (amountFilledInETH)
        // 3. Mint (amountToMint) to msg.sender
        address pair = IUniswapV2Factory(factory).getPair(toToken, WETH);
        (uint112 toTokenReserve, uint112 wethReserve, ) = IUniswapV2Pair(pair).getReserves();
        uint256 amountFilledInETH = quote(amountOut, toTokenReserve, wethReserve);
        uint256 amountToMint = amountFilledInETH.mul(rewardPerAmountFilled) / 10**18;
        rewardToken.mint(msg.sender, amountToMint);
    }

    function fillOrders(FillOrderArgs[] memory args)
        public
        override
        returns (uint256[] memory amountsOut)
    {
        amountsOut = new uint256[](args.length);
        for (uint256 i = 0; i < args.length; i++) {
            amountsOut[i] = fillOrder(args[i]);
        }
    }
}