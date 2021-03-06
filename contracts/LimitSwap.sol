pragma solidity ^0.5.0;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";


interface InteractiveTaker {
    function interact(
        IERC20 makerAsset,
        IERC20 takerAsset,
        uint256 takingAmount,
        uint256 expectedAmount
    ) external;
}


library LimitOrder {
    struct Data {
        address makerAddress;
        address takerAddress;
        IERC20 makerAsset;
        IERC20 takerAsset;
        uint256 makerAmount;
        uint256 takerAmount;
        uint256 expiration;
    }

    function hash(Data memory order, address contractAddress) internal pure returns(bytes32) {
        return keccak256(abi.encodePacked(
            contractAddress,
            order.makerAddress,
            order.takerAddress,
            order.makerAsset,
            order.takerAsset,
            order.makerAmount,
            order.takerAmount,
            order.expiration
        ));
    }
}

library ArrayHelper {
    function one(uint256 elem) internal pure returns(uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = elem;
    }

    function one(address elem) internal pure returns(address[] memory arr) {
        arr = new address[](1);
        arr[0] = elem;
    }
}


contract Depositor {

    using SafeMath for uint256;

    mapping(address => uint256) private _balances;

    modifier deposit(bytes4 sig) {
        if (msg.value > 0 && sig == msg.sig) {
            _deposit();
        }
        _;
    }

    modifier depositAndWithdraw(bytes4 sig) {
        uint256 prevBalance = balanceOf(msg.sender);
        if (msg.value > 0 && sig == msg.sig) {
            _deposit();
        }
        _;
        if (balanceOf(msg.sender) > prevBalance) {
            _withdraw(balanceOf(msg.sender).sub(prevBalance));
        }
    }

    function balanceOf(address user) public view returns(uint256) {
        return _balances[user];
    }

    function _deposit() internal {
        _mint(msg.sender, msg.value);
    }

    function _withdraw(uint256 amount) internal {
        _burn(msg.sender, amount);
        msg.sender.transfer(amount);
    }

    function _mint(address user, uint256 amount) internal {
        _balances[user] = _balances[user].add(amount);
    }

    function _burn(address user, uint256 amount) internal {
        _balances[user] = _balances[user].sub(amount);
    }
}


contract LimitSwap is Depositor {

    using SafeERC20 for IERC20;
    using LimitOrder for LimitOrder.Data;

    mapping(bytes32 => uint256) public remainings;

    event LimitOrderUpdated(
        address indexed makerAddress,
        address takerAddress,
        IERC20 indexed makerAsset,
        IERC20 indexed takerAsset,
        uint256 makerAmount,
        uint256 takerAmount,
        uint256 expiration,
        uint256 remaining
    );

    function available(
        address[] memory makerAddresses,
        address[] memory takerAddresses,
        IERC20 makerAsset,
        IERC20 takerAsset,
        uint256[] memory makerAmounts,
        uint256[] memory takerAmounts,
        uint256[] memory expirations
    )
        public
        view
        returns(uint256 makerFilledAmount)
    {
        uint256[] memory userAvailable = new uint256[](makerAddresses.length);

        for (uint i = 0; i < makerAddresses.length; i++) {
            if (expirations[i] < now) {
                continue;
            }

            if (makerAsset == IERC20(0)) {
                makerFilledAmount = makerFilledAmount.add(makerAmounts[i]);
                continue;
            }

            LimitOrder.Data memory order = LimitOrder.Data({
                makerAddress: makerAddresses[i],
                takerAddress: takerAddresses[i],
                makerAsset: makerAsset,
                takerAsset: takerAsset,
                makerAmount: makerAmounts[i],
                takerAmount: takerAmounts[i],
                expiration: expirations[i]
            });

            bool found = false;
            for (uint j = 0; j < i; j++) {
                if (makerAddresses[j] == makerAddresses[i]) {
                    found = true;
                    if (userAvailable[j] > makerAmounts[i]) {
                        userAvailable[j] = userAvailable[j].sub(makerAmounts[i]);
                        makerFilledAmount = makerFilledAmount.add(makerAmounts[i]);
                    } else {
                        makerFilledAmount = makerFilledAmount.add(userAvailable[j]);
                        userAvailable[j] = 0;
                    }
                    break;
                }
            }

            if (!found) {
                userAvailable[i] = Math.min(
                    makerAsset.balanceOf(makerAddresses[i]),
                    makerAsset.allowance(makerAddresses[i], address(this))
                );
                uint256 maxOrderSize = Math.min(
                    remainings[order.hash(address(this))],
                    userAvailable[i]
                );
                userAvailable[i] = userAvailable[i].sub(maxOrderSize);
                makerFilledAmount = makerFilledAmount.add(maxOrderSize);
            }
        }
    }

    function makeOrder(
        address takerAddress,
        IERC20 makerAsset,
        IERC20 takerAsset,
        uint256 makerAmount,
        uint256 takerAmount,
        uint256 expiration
    )
        public
        payable
        deposit(this.makeOrder.selector)
    {
        LimitOrder.Data memory order = LimitOrder.Data({
            makerAddress: msg.sender,
            takerAddress: takerAddress,
            makerAsset: makerAsset,
            takerAsset: takerAsset,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: expiration
        });

        bytes32 orderHash = order.hash(address(this));
        require(remainings[orderHash] == 0, "LimitSwap: existing order");

        if (makerAsset == IERC20(0)) {
            require(makerAmount == msg.value, "LimitSwap: for ETH makerAmount should be equal to msg.value");
        } else {
            require(msg.value == 0, "LimitSwap: msg.value should be 0 when makerAsset in not ETH");
        }

        remainings[orderHash] = makerAmount;
        _updateOrder(order, orderHash);
    }

    function cancelOrder(
        address takerAddress,
        IERC20 makerAsset,
        IERC20 takerAsset,
        uint256 makerAmount,
        uint256 takerAmount,
        uint256 expiration
    )
        public
    {
        LimitOrder.Data memory order = LimitOrder.Data({
            makerAddress: msg.sender,
            takerAddress: takerAddress,
            makerAsset: makerAsset,
            takerAsset: takerAsset,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: expiration
        });

        bytes32 orderHash = order.hash(address(this));
        require(remainings[orderHash] != 0, "LimitSwap: not existing or already filled order");

        if (makerAsset == IERC20(0)) {
            _withdraw(remainings[orderHash]);
        }

        remainings[orderHash] = 0;
        _updateOrder(order, orderHash);
    }

    function takeOrdersAvailable(
        address payable[] memory makerAddresses,
        address[] memory takerAddresses,
        IERC20 makerAsset,
        IERC20 takerAsset,
        uint256[] memory makerAmounts,
        uint256[] memory takerAmounts,
        uint256[] memory expirations,
        uint256 takingAmount
    )
        public
        payable
        depositAndWithdraw(this.takeOrdersAvailable.selector)
        returns(uint256 takerVolume)
    {
        for (uint i = 0; takingAmount > takerVolume && i < makerAddresses.length; i++) {
            takerVolume = takerVolume.sub(
                takeOrderAvailable(
                    makerAddresses[i],
                    takerAddresses[i],
                    makerAsset,
                    takerAsset,
                    makerAmounts[i],
                    takerAmounts[i],
                    expirations[i],
                    takingAmount.sub(takerVolume),
                    false
                )
            );
        }
    }

    function takeOrderAvailable(
        address payable makerAddress,
        address takerAddress,
        IERC20 makerAsset,
        IERC20 takerAsset,
        uint256 makerAmount,
        uint256 takerAmount,
        uint256 expiration,
        uint256 takingAmount,
        bool interactive
    )
        public
        payable
        depositAndWithdraw(this.takeOrderAvailable.selector)
        returns(uint256 takerVolume)
    {
        takerVolume = Math.min(
            takingAmount,
            available(
                ArrayHelper.one(makerAddress),
                ArrayHelper.one(takerAddress),
                makerAsset,
                takerAsset,
                ArrayHelper.one(makerAmount),
                ArrayHelper.one(takerAmount),
                ArrayHelper.one(expiration)
            )
        );
        takeOrder(
            makerAddress,
            takerAddress,
            makerAsset,
            takerAsset,
            makerAmount,
            takerAmount,
            expiration,
            takerVolume,
            interactive
        );
    }

    function takeOrder(
        address payable makerAddress,
        address takerAddress,
        IERC20 makerAsset,
        IERC20 takerAsset,
        uint256 makerAmount,
        uint256 takerAmount,
        uint256 expiration,
        uint256 takingAmount,
        bool interactive
    )
        public
        payable
        depositAndWithdraw(this.takeOrder.selector)
    {
        require(block.timestamp <= expiration, "LimitSwap: order already expired");
        require(takerAddress == address(0) || takerAddress == msg.sender, "LimitSwap: access denied to this order");

        LimitOrder.Data memory order = LimitOrder.Data({
            makerAddress: makerAddress,
            takerAddress: takerAddress,
            makerAsset: makerAsset,
            takerAsset: takerAsset,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: expiration
        });

        bytes32 orderHash = order.hash(address(this));
        remainings[orderHash] = remainings[orderHash].sub(takingAmount, "LimitSwap: remaining amount is less than taking amount");
        _updateOrder(order, orderHash);

        // Maker => Taker
        if (makerAsset == IERC20(0)) {
            _burn(makerAddress, takingAmount);
            msg.sender.transfer(takingAmount);
        } else {
            makerAsset.safeTransferFrom(makerAddress, msg.sender, takingAmount);
        }

        // Taker can handle funds interactively
        uint256 expectedAmount = takingAmount.mul(makerAmount).div(takerAmount);
        if (interactive) {
            InteractiveTaker(msg.sender).interact(makerAsset, takerAsset, takingAmount, expectedAmount);
        }

        // Taker => Maker
        if (takerAsset == IERC20(0)) {
            _burn(msg.sender, expectedAmount);
            makerAddress.transfer(expectedAmount);
        } else {
            require(msg.value == 0, "LimitSwap: msg.value should be 0 when takerAsset in not ETH");
            takerAsset.safeTransferFrom(msg.sender, makerAddress, expectedAmount);
        }
    }

    function _updateOrder(
        LimitOrder.Data memory order,
        bytes32 orderHash
    )
        internal
    {
        emit LimitOrderUpdated(
            order.makerAddress,
            order.takerAddress,
            order.makerAsset,
            order.takerAsset,
            order.makerAmount,
            order.takerAmount,
            order.expiration,
            remainings[orderHash]
        );
    }
}
