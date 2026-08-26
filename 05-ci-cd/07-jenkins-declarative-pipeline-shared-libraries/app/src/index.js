/**
 * Sample E-Commerce Cart Service Microservice
 */
function createCart(userId) {
    if (!userId) throw new Error("userId is required");
    return {
        cartId: `cart-${userId}-${Date.now()}`,
        userId: userId,
        items: [],
        total: 0.0,
        currency: "USD"
    };
}

function addItem(cart, item, price, quantity = 1) {
    if (!cart) throw new Error("cart is required");
    if (!item || price < 0 || quantity <= 0) throw new Error("Invalid item arguments");
    cart.items.push({ item, price, quantity });
    cart.total = Number((cart.total + (price * quantity)).toFixed(2));
    return cart;
}

module.exports = { createCart, addItem };
